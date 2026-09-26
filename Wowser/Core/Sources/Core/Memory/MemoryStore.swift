import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

// The memory store: an on-disk, FTS-indexed event log of what happened in the
// browser, one SQLite database per website data store ("scope"). Off by
// default; the user turns it on per scope in Settings › Memory.
//
// Performance rules, in order of importance:
//   1. Every hook called from the main thread starts with a cheap `isActive`
//      / `isEnabled(scope)` check and does nothing else unless memory is on.
//   2. Everything that touches SQLite or does OCR runs on utility-QoS queues.
//      Main-thread work is limited to reading a few fields off BrowserState
//      and kicking off WebKit snapshots (which render out of process).
//   3. Backpressure drops content instead of queueing it: at most
//      `maxPendingWrites` inserts wait for the DB, and at most one OCR per pane
//      is in flight. Losing a screen capture is fine; a stalled browser isn't.
//   4. Nothing here is touched until `startLate()` runs, several seconds after
//      launch, and only if some scope is enabled.

public struct MemoryEvent {
    public var kind: String          // visit | screen | terminal | agent | download | typed | click | form
    public var pageType: String      // web | terminal | agent | files | vscode | notes | chat | other
    public var paneID: String?
    public var tabID: String?
    public var url: URL?
    public var title: String?
    public var description: String?
    public var text: String?
    public var parentPaneID: String?
    public var parentURL: URL?
    public var parentTitle: String?
    public var extra: [String: Any]?
    /// The space (profile) the tab belonged to when this was recorded.
    public var spaceID: String?
    public var spaceName: String?
    public var ts = Date()

    public init(kind: String, pageType: String, paneID: String? = nil, tabID: String? = nil, url: URL? = nil, title: String? = nil, description: String? = nil, text: String? = nil, parentPaneID: String? = nil, parentURL: URL? = nil, parentTitle: String? = nil, extra: [String: Any]? = nil) {
        self.kind = kind; self.pageType = pageType; self.paneID = paneID; self.tabID = tabID
        self.url = url; self.title = title; self.description = description; self.text = text
        self.parentPaneID = parentPaneID; self.parentURL = parentURL; self.parentTitle = parentTitle; self.extra = extra
    }
}

public final class MemoryStore: ObservableObject {
    public static let shared = MemoryStore()

    /// True while at least one scope is enabled and capture has started.
    /// Read on hot paths (info changes, key events); written on main only.
    public private(set) var isActive = false

    /// Serial queue owning the SQLite connections and the line-diff state.
    let queue = DispatchQueue(label: "MemoryStore", qos: .utility)
    /// Long-running agent SQL goes here so it never blocks writes.
    let readQueue = DispatchQueue(label: "MemoryStore.read", qos: .utility)
    /// OCR and image hashing.
    let ocrQueue = DispatchQueue(label: "MemoryStore.ocr", qos: .utility)

    private let lock = NSLock()
    private var enabledScopes: Set<UUID> = []
    private var pendingWrites = 0
    private let maxPendingWrites = 400

    // queue-only
    private var dbs: [UUID: MemoryDB] = [:]
    private var failedScopes: Set<UUID> = []
    var lastLines: [String: [String]] = [:]
    /// Lines that were new at the previous capture, per key (see `diffStableLines`).
    var pendingLines: [String: [String]] = [:]

    // main-only
    var started = false
    var spawnParents: [ID<WebContent>: (paneID: ID<WebContent>, url: URL?, title: String?)] = [:]
    private var captureTimer: DispatchSourceTimer?
    private var subscriptions = Set<AnyCancellable>()

    /// Overview state per scope, for Settings and BrowserJS. Main-only.
    @Published public var overviews: [UUID: MemoryOverviewInfo] = [:]
    /// Mirror of the enabled set for SwiftUI (the lock-protected set isn't observable). Main-only.
    @Published public private(set) var enabledScopesForUI: Set<UUID> = []
    var overviewRuns: [UUID: OverviewRun] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Called from `Preheat` well after launch. Loads the enabled-scope list
    /// and starts capture only if something is enabled.
    public func startLate() {
        assert(Thread.isMainThread)
        let scopes = Set(DefaultsKeys.memoryEnabledScopes.stringArrayValue().compactMap(UUID.init(uuidString:)))
        lock.lock(); enabledScopes = scopes; lock.unlock()
        enabledScopesForUI = scopes
        if !scopes.isEmpty { start() }
    }

    public func isEnabled(_ scope: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabledScopes.contains(scope)
    }

    public var enabledScopeIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return enabledScopes
    }

    public func setEnabled(_ enabled: Bool, scope: UUID) {
        assert(Thread.isMainThread)
        lock.lock()
        if enabled { enabledScopes.insert(scope) } else { enabledScopes.remove(scope) }
        let scopes = enabledScopes
        lock.unlock()
        DefaultsKeys.memoryEnabledScopes.setStringArray(scopes.map(\.uuidString).sorted())
        enabledScopesForUI = scopes
        if scopes.isEmpty { stop() } else { start() }
        if enabled { loadOverview(scope: scope) }
    }

    private func start() {
        guard !started else { return }
        started = true
        isActive = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 5.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.captureTick() } }
        timer.resume()
        captureTimer = timer
        startTypedTextCapture()
        queue.async { self.pruneOldEvents() }
    }

    private func stop() {
        guard started else { return }
        started = false
        isActive = false
        captureTimer?.cancel()
        captureTimer = nil
        stopTypedTextCapture()
        subscriptions.removeAll()
    }

    // MARK: - Storage

    static var directory: URL {
        let appDir = "WowserDataStores-\(isProd() ? "prod" : "dev")"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appDir)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Unknown")
            .appendingPathComponent("Memory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// queue-only.
    func db(for scope: UUID) -> MemoryDB? {
        if let existing = dbs[scope] { return existing }
        if failedScopes.contains(scope) { return nil }
        let path = Self.directory.appendingPathComponent(scope.uuidString + ".sqlite").path
        do {
            let db = try MemoryDB(path: path)
            dbs[scope] = db
            return db
        } catch {
            print("[🧠 memory] failed to open \(path): \(error)")
            failedScopes.insert(scope)
            return nil
        }
    }

    /// Runs `block` with the scope's DB on the write queue.
    func perform<T>(scope: UUID, _ block: @escaping (MemoryDB) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let db = self.db(for: scope) else {
                    cont.resume(throwing: MemoryDB.DBError.open("could not open memory database for \(scope)"))
                    return
                }
                do { cont.resume(returning: try block(db)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Runs a read-only agent query on the read queue.
    func performRead(scope: UUID, sql: String, params: [Any?], limit: Int) async throws -> [[String: Any]] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let db = self.db(for: scope) else {
                    cont.resume(throwing: MemoryDB.DBError.open("could not open memory database for \(scope)"))
                    return
                }
                self.readQueue.async {
                    do { cont.resume(returning: try db.readOnlyQuery(sql, params, maxRows: limit)) } catch { cont.resume(throwing: error) }
                }
            }
        }
    }

    /// Storage caps. Per-row caps bound what one event (and its FTS entry) can
    /// cost; `maxRows` bounds the table as a whole, oldest rows going first.
    static let maxTitleChars = 500
    static let maxDescriptionChars = 2_000
    static let maxTextChars = 30_000
    static let maxExtraChars = 16_000
    static let maxRows = 300_000
    static let maxAgeDays = 180

    private func pruneOldEvents() {
        let cutoff = Date().addingTimeInterval(-Double(Self.maxAgeDays) * 24 * 3600).timeIntervalSince1970
        for scope in enabledScopeIDs {
            guard let db = db(for: scope) else { continue }
            try? db.run("DELETE FROM events WHERE ts < ?", [cutoff])
            try? db.run("DELETE FROM events WHERE id < (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?)", [Self.maxRows])
        }
    }

    // MARK: - Recording

    /// Enqueue an insert. Drops the event if too many writes are already waiting.
    public func record(scope: UUID, _ event: MemoryEvent) {
        guard isEnabled(scope) else { return }
        lock.lock()
        if pendingWrites >= maxPendingWrites { lock.unlock(); return }
        pendingWrites += 1
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pendingWrites -= 1; self.lock.unlock() }
            guard let db = self.db(for: scope) else { return }
            self.insert(event, into: db)
        }
    }

    /// Clip `s` to `max` characters, marking the cut.
    static func clipped(_ s: String?, _ max: Int) -> String? {
        guard let s = s?.nilIfEmpty else { return nil }
        return s.count <= max ? s : String(s.prefix(max)) + "…[truncated]"
    }

    /// `extra` as JSON, or a stub if it would exceed the cap.
    static func extraJSON(_ extra: [String: Any]?) -> String? {
        guard let dict = extra, JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s.count <= maxExtraChars ? s : "{\"truncated\":true,\"bytes\":\(data.count)}"
    }

    /// queue-only
    func insert(_ e: MemoryEvent, into db: MemoryDB) {
        do {
            try db.run("""
            INSERT INTO events (ts, kind, page_type, pane_id, tab_id, url, domain, title, description, text, parent_pane_id, parent_url, parent_title, extra, space_id, space)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [e.ts.timeIntervalSince1970, e.kind, e.pageType, e.paneID, e.tabID,
                  e.url?.absoluteString, e.url.flatMap(Self.domain(of:)),
                  Self.clipped(e.title, Self.maxTitleChars), Self.clipped(e.description, Self.maxDescriptionChars), Self.clipped(e.text, Self.maxTextChars),
                  e.parentPaneID, e.parentURL?.absoluteString, Self.clipped(e.parentTitle, Self.maxTitleChars), Self.extraJSON(e.extra),
                  e.spaceID, Self.clipped(e.spaceName, 200)])
        } catch {
            print("[🧠 memory] insert failed: \(error)")
        }
    }

    /// Fill in title/description on the most recent visit row for this pane+url
    /// as they arrive after navigation.
    func updateVisitMeta(scope: UUID, paneID: String, url: URL, title: String?, description: String?) {
        guard isEnabled(scope), title?.nilIfEmpty != nil || description?.nilIfEmpty != nil else { return }
        queue.async {
            guard let db = self.db(for: scope) else { return }
            try? db.run("""
            UPDATE events SET title = COALESCE(?, title), description = COALESCE(?, description)
            WHERE id = (SELECT id FROM events WHERE kind = 'visit' AND pane_id = ? AND url = ? ORDER BY id DESC LIMIT 1)
            """, [title?.nilIfEmpty, description?.nilIfEmpty, paneID, url.absoluteString])
        }
    }

    /// (id, display name) of the space a pane currently lives in. Main thread.
    static func space(forPane paneID: ID<WebContent>, in state: BrowserState) -> (id: String, name: String)? {
        guard let profile = state.profile(forWebContentId: paneID) else { return nil }
        return (profile.id.raw, profile.displayName)
    }

    static func domain(of url: URL) -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return url.hostWithoutWWW.nilIfEmpty
    }

    static func pageType(for url: URL?) -> String {
        guard let url else { return "other" }
        if let key = NativePageKey(url: url) { return key.kindString }
        if url.scheme == TangSchemeHandler.scheme { return url.host == "notes" ? "notes" : "web" }
        if url.scheme == "http" || url.scheme == "https" { return "web" }
        return "other"
    }

    // MARK: - Line diffing

    /// Stores `lines` as the new baseline for `key` and returns the lines that
    /// weren't present last time (multiset difference, order preserved). The
    /// first capture for a key returns everything.
    /// queue-only.
    func diffLines(key: String, lines: [String]) -> [String] {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
        let prev = lastLines[key]
        if lastLines.count > 300, prev == nil {
            // Forget baselines for panes we haven't seen in a while, crudely.
            lastLines.removeAll(keepingCapacity: true)
        }
        lastLines[key] = Array(cleaned.suffix(3000))
        guard let prev else { return cleaned }
        var counts: [String: Int] = [:]
        for l in prev { counts[l, default: 0] += 1 }
        var out: [String] = []
        for l in cleaned {
            if let c = counts[l], c > 0 { counts[l] = c - 1 } else { out.append(l) }
        }
        return out
    }

    /// Like `diffLines`, but a line only counts once it has been on screen for
    /// two consecutive captures: it was new last time AND is still present
    /// now. Filters out spinner frames, progress counters and half-typed
    /// input that TUIs redraw every tick, at the cost of ~one tick of latency.
    /// queue-only.
    func diffStableLines(key: String, lines: [String]) -> [String] {
        let new = diffLines(key: key, lines: lines)
        let candidates = pendingLines[key] ?? []
        pendingLines[key] = new
        if pendingLines.count > 300 { pendingLines.removeAll(keepingCapacity: true); pendingLines[key] = new }
        guard !candidates.isEmpty else { return [] }
        // Multiset intersection of last tick's new lines with what's on screen now.
        var counts: [String: Int] = [:]
        for l in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) { counts[l, default: 0] += 1 }
        var out: [String] = []
        for l in candidates {
            if let c = counts[l], c > 0 { counts[l] = c - 1; out.append(l) }
        }
        return out
    }

    func resetBaseline(key: String) {
        queue.async { self.lastLines[key] = nil; self.pendingLines[key] = nil }
    }

    /// Diff on the queue and record the new lines as one event. With
    /// `requireStable`, lines must survive two captures (see `diffStableLines`).
    func ingestLines(scope: UUID, key: String, lines: [String], requireStable: Bool = false, makeEvent: @escaping (String) -> MemoryEvent) {
        guard isEnabled(scope) else { return }
        queue.async {
            let new = requireStable ? self.diffStableLines(key: key, lines: lines) : self.diffLines(key: key, lines: lines)
            guard !new.isEmpty else { return }
            let text = new.joined(separator: "\n")
            guard let db = self.db(for: scope) else { return }
            self.insert(makeEvent(text), into: db)
        }
    }

    // MARK: - Scopes (for Settings / BrowserJS)

    public struct ScopeInfo: Equatable, Identifiable {
        public var id: UUID
        public var names: [String]
        public var enabled: Bool
    }

    /// All data-store scopes known to BrowserState, grouped from profiles.
    public static func scopes(in state: BrowserState) -> [ScopeInfo] {
        var byStore: [UUID: [Profile]] = [:]
        for p in state.profiles.values where !p.isHidden { byStore[p.dataStoreUUID, default: []].append(p) }
        let enabled = MemoryStore.shared.enabledScopeIDs
        return byStore.map { (uuid, profiles) in
            let names = profiles.sorted(by: { $0.creationOrder < $1.creationOrder }).map(\.displayName)
            return ScopeInfo(id: uuid, names: names, enabled: enabled.contains(uuid))
        }.sorted { a, b in
            (a.names.first ?? "") < (b.names.first ?? "")
        }
    }

    /// Resolve a scope for a BrowserJS call: explicit id, else the origin
    /// pane's profile, else the only enabled scope. Main thread.
    func resolveScope(explicit: String?, originPane: ID<WebContent>?) throws -> UUID {
        if let explicit {
            guard let uuid = UUID(uuidString: explicit) else { throw BrowserJSError.invalidArgs("scope must be a data store UUID") }
            return uuid
        }
        if let originPane, let profile = BrowserStore.shared.model.profile(forWebContentId: originPane) {
            return profile.dataStoreUUID
        }
        let enabled = enabledScopeIDs
        if enabled.count == 1, let only = enabled.first { return only }
        throw BrowserJSError.invalidArgs("scope (call browser.memory.scopes() to list them)")
    }
}
