import Foundation
import Combine

/// A body of local data that participates in sync (browser state, history,
/// autofill). Sources translate between their native model and flat sync
/// records; the engine does everything else.
public protocol SyncSource: AnyObject {
    /// Stable id; keys the engine's per-source bookkeeping.
    var id: String { get }
    var collections: [SyncCollectionSpec] { get }
    /// Fires (any thread) when local data may have changed.
    var localChanges: AnyPublisher<Void, Never> { get }
    /// Current local data, called on the engine queue. Return nil when the
    /// data can't be read meaningfully right now (e.g. no window yet): the
    /// source is skipped this round rather than read as empty.
    func project() -> SyncProjection?
    /// Fold remote changes into local data, in the source's own transaction.
    /// Call `completion` (any thread) once it's applied.
    func apply(_ update: SyncUpdate, completion: @escaping () -> Void)
}

/// Where the engine keeps its own state between launches.
public protocol SyncEngineStorage {
    func load() -> SyncEngineState?
    func save(_ state: SyncEngineState)
}

public struct SyncDeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var lastSeq: Int
    public var lastBatchAt: Date
}

/// Two devices wrote different values to the same field within
/// `SyncEngine.conflictWindow`; one won. Kept for the debug UI.
public struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var at: Date
    public var col: String
    public var key: String
    public var field: String
    public var winner: String
    public var winnerValue: String
    public var loser: String
    public var loserValue: String
}

public struct SyncLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var at: Date
    public var message: String
}

/// Everything the engine persists.
public struct SyncEngineState: Codable, Equatable {
    public var deviceID: String
    public var clock: HLCClock
    public var nextSeq = 1
    /// Highest batch seq merged, per remote device.
    public var cursor: [String: Int] = [:]
    public var doc = SyncDocument()
    /// Per source: the projection last diffed (with order keys resolved).
    /// Absent until the source has joined.
    public var previous: [String: SyncProjection] = [:]
    /// Batches written but not yet accepted by the transport.
    public var outbox: [SyncBatch] = []
    public var devices: [String: SyncDeviceInfo] = [:]
    public var conflicts: [SyncConflict] = []
    public var errors: [SyncLogEntry] = []
    public var stats = Stats()

    public struct Stats: Codable, Equatable {
        public var batchesPublished = 0
        public var opsPublished = 0
        public var batchesReceived = 0
        public var opsReceived = 0
        public var lastLocalWriteAt: Date?
        public var lastPublishAt: Date?
        public var lastFetchAt: Date?
        public var lastRemoteChangeAt: Date?
    }

    public init(deviceID: String) {
        self.deviceID = deviceID
        self.clock = HLCClock(device: deviceID)
    }
}

/// Live engine status for the settings pane.
public struct SyncStatus: Equatable {
    public var running = false
    public var deviceID = ""
    public var deviceName = ""
    public var transport = ""
    public var stats = SyncEngineState.Stats()
    public var outboxCount = 0
    public var devices: [SyncDeviceInfo] = []
    public var conflicts: [SyncConflict] = []
    public var errors: [SyncLogEntry] = []
    public var recordCounts: [String: Int] = [:]
    /// Remote values not (yet) reflected locally, e.g. a remote navigation
    /// waiting for its tab to be reopened.
    public var unappliedFields = 0
    public var joinedSources: [String] = []

    public init() {}
}

/// Runs sync: diffs each source's projection into ops, appends them to this
/// device's log via the transport, merges other devices' ops into the
/// document, and hands changes back to sources. All state lives on `queue`.
public final class SyncEngine {
    public static let conflictWindow: TimeInterval = 30
    static let maxConflicts = 50
    static let maxErrors = 50

    public let sources: [SyncSource]
    public let transport: SyncTransport
    public let deviceName: String
    let storage: SyncEngineStorage
    let specs: [String: SyncCollectionSpec]
    let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    let throttle: TimeInterval
    let now: () -> Date

    private(set) var state: SyncEngineState
    private var joining = Set<String>()
    private var running = false
    private var tickScheduled = false
    private var subscriptions = Set<AnyCancellable>()
    private var dirtySince: Date?
    private var lastSave = Date.distantPast
    private var lastDivergenceRetry = Date.distantPast
    private let statusSubject = CurrentValueSubject<SyncStatus, Never>(SyncStatus())

    public var statusPublisher: AnyPublisher<SyncStatus, Never> { statusSubject.eraseToAnyPublisher() }
    public var status: SyncStatus { statusSubject.value }

    public init(sources: [SyncSource], transport: SyncTransport, storage: SyncEngineStorage, deviceName: String, throttle: TimeInterval = 1, queue: DispatchQueue? = nil, now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.transport = transport
        self.storage = storage
        self.deviceName = deviceName
        self.throttle = throttle
        self.now = now
        self.queue = queue ?? DispatchQueue(label: "SyncEngine", qos: .utility)
        var specs = [String: SyncCollectionSpec]()
        for source in sources {
            for spec in source.collections { specs[spec.name] = spec }
        }
        self.specs = specs
        self.state = storage.load() ?? SyncEngineState(deviceID: UUID().uuidString)
        self.queue.setSpecific(key: queueKey, value: true)
    }

    public var deviceID: String { onQueue { state.deviceID } }

    // MARK: - Lifecycle

    public func start() {
        onQueue {
            guard !running else { return }
            running = true
            for source in sources {
                source.localChanges
                    .throttle(for: .seconds(throttle), scheduler: queue, latest: true)
                    .sink { [weak self] in self?.scheduleTick() }
                    .store(in: &subscriptions)
            }
            transport.onRemoteChange = { [weak self] in self?.scheduleTick() }
            transport.start()
            scheduleTick()
            publishStatus()
        }
    }

    public func stop() {
        onQueue {
            guard running else { return }
            running = false
            subscriptions.removeAll()
            transport.onRemoteChange = nil
            transport.stop()
            storage.save(state)
            publishStatus()
        }
    }

    /// Persist now (e.g. at app termination).
    public func flush() {
        onQueue {
            storage.save(state)
            lastSave = now()
            dirtySince = nil
        }
    }

    public func scheduleTick() {
        queue.async { [weak self] in
            guard let self, self.running, !self.tickScheduled else { return }
            self.tickScheduled = true
            self.queue.async {
                self.tickScheduled = false
                guard self.running else { return }
                self.tick()
            }
        }
    }

    /// Run sync rounds synchronously until nothing happens. For tests (with
    /// sources whose `apply` is synchronous) and "Sync Now".
    @discardableResult
    public func runUntilQuiet(maxRounds: Int = 20) -> Int {
        onQueue {
            var rounds = 0
            while rounds < maxRounds {
                rounds += 1
                if !tick() { break }
            }
            return rounds
        }
    }

    // MARK: - The sync round

    /// One round: flush local edits, pull remote batches, hand changes back.
    /// Returns whether anything happened.
    @discardableResult
    func tick() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var didWork = false
        flushOutbox()

        // 1. Local edits first, so a remote value merged below can't land
        //    on top of an edit we haven't logged yet.
        if emitLocalWrites() { didWork = true }

        // 2. Remote batches.
        var changed = [String: Set<String>]()
        var changedParents = [String: Set<String>]()
        if mergeRemote(changed: &changed, changedParents: &changedParents) { didWork = true }

        // 3. Remote values local data hasn't absorbed yet (e.g. an apply that
        //    was skipped because the user was mid-edit). Retried at most every
        //    few seconds so an unabsorbable value can't spin.
        let divergent = divergentKeys()
        if !divergent.isEmpty, !changed.isEmpty || now().timeIntervalSince(lastDivergenceRetry) > 5 {
            lastDivergenceRetry = now()
            for (col, keys) in divergent.keys { changed[col, default: []].formUnion(keys) }
            for (col, parents) in divergent.parents { changedParents[col, default: []].formUnion(parents) }
        }

        // 4. Joins (first sync for a source), then hand changes to sources.
        for source in sources where state.previous[source.id] == nil && !joining.contains(source.id) {
            beginJoin(source)
            didWork = true
        }
        for source in sources where state.previous[source.id] != nil {
            let cols = Set(source.collections.map(\.name))
            let update = SyncUpdate(
                doc: state.doc,
                changed: changed.filter { cols.contains($0.key) },
                changedParents: changedParents.filter { cols.contains($0.key) },
                expected: state.previous[source.id]!)
            guard !update.isEmpty else { continue }
            source.apply(update) {}
        }

        markDirty()
        saveIfNeeded()
        publishStatus(unapplied: divergent.fieldCount)
        return didWork
    }

    private func emitLocalWrites() -> Bool {
        var writes = [SyncDiff.Write]()
        for source in sources where state.previous[source.id] != nil && !joining.contains(source.id) {
            guard let projection = source.project() else { continue }
            let (w, resolved) = SyncDiff.diff(specs: specs, projection: projection, previous: state.previous[source.id], doc: state.doc)
            state.previous[source.id] = resolved
            writes += w
        }
        guard !writes.isEmpty else { return false }
        let ops = writes.map { w in SyncOp(col: w.col, key: w.key, f: w.f, v: w.v, c: state.clock.tick(now: now())) }
        for op in ops {
            state.doc.merge(op, policy: policy(op.col))
        }
        let batch = SyncBatch(device: state.deviceID, deviceName: deviceName, seq: state.nextSeq, createdAt: now(), ops: ops)
        state.nextSeq += 1
        state.outbox.append(batch)
        state.stats.lastLocalWriteAt = now()
        flushOutbox()
        return true
    }

    private func flushOutbox() {
        while let batch = state.outbox.first {
            do {
                try transport.publish(batch) {
                    SyncBatch(device: state.deviceID, deviceName: deviceName, seq: batch.seq, createdAt: now(), snapshot: true, ops: state.doc.allOps())
                }
                state.outbox.removeFirst()
                state.stats.batchesPublished += 1
                state.stats.opsPublished += batch.ops.count
                state.stats.lastPublishAt = now()
            } catch {
                logError("Publish failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func mergeRemote(changed: inout [String: Set<String>], changedParents: inout [String: Set<String>]) -> Bool {
        let batches: [SyncBatch]
        do {
            batches = try transport.fetch(after: state.cursor)
            state.stats.lastFetchAt = now()
        } catch {
            logError("Fetch failed: \(error.localizedDescription)")
            return false
        }
        var didWork = false
        for batch in batches.sorted(by: { ($0.device, $0.seq) < ($1.device, $1.seq) }) {
            guard batch.device != state.deviceID, batch.seq > (state.cursor[batch.device] ?? 0) else { continue }
            didWork = true
            for op in batch.ops {
                state.clock.observe(op.c)
                let spec = specs[op.col]
                let before = state.doc.field(op.col, op.key, op.f)
                let oldParent = state.doc.parent(op.col, op.key)
                let outcome = state.doc.merge(op, policy: policy(op.col))
                noteConflict(op: op, before: before)
                guard case .changed = outcome else { continue }
                changed[op.col, default: []].insert(op.key)
                if spec?.ordered == true {
                    if let oldParent { changedParents[op.col, default: []].insert(oldParent) }
                    if let newParent = state.doc.parent(op.col, op.key) { changedParents[op.col, default: []].insert(newParent) }
                }
            }
            state.cursor[batch.device] = batch.seq
            state.stats.batchesReceived += 1
            state.stats.opsReceived += batch.ops.count
            state.stats.lastRemoteChangeAt = now()
            state.devices[batch.device] = SyncDeviceInfo(id: batch.device, name: batch.deviceName, lastSeq: batch.seq, lastBatchAt: batch.createdAt)
        }
        return didWork
    }

    private func noteConflict(op: SyncOp, before: SyncField?) {
        guard let before, before.c.device != op.c.device, before.v != op.v,
              abs(Double(before.c.millis - op.c.millis)) < Self.conflictWindow * 1000,
              !SyncReservedField.all.contains(op.f) || op.f == SyncReservedField.deleted,
              // Fields merged by value (max etc.) combine rather than conflict.
              (specs[op.col]?.policy as? FieldMergePolicy)?.overrides[op.f] == nil
        else { return }
        let after = state.doc.field(op.col, op.key, op.f) ?? before
        let loser = after.c == before.c ? SyncField(v: op.v, c: op.c) : before
        state.conflicts.append(SyncConflict(
            at: now(), col: op.col, key: op.key, field: op.f,
            winner: after.c.device, winnerValue: Self.summary(after.v),
            loser: loser.c.device, loserValue: Self.summary(loser.v)))
        if state.conflicts.count > Self.maxConflicts { state.conflicts.removeFirst(state.conflicts.count - Self.maxConflicts) }
    }

    static func summary(_ v: SyncValue) -> String {
        let s: String
        switch v {
        case .string(let str): s = str
        default: s = (try? String(data: JSONEncoder().encode(v), encoding: .utf8) ?? "") ?? ""
        }
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    // MARK: - Joining

    /// First sync for a source on this device: apply everything already in
    /// the merged doc (remote wins for records both sides have, e.g. the
    /// default space), then remember the result as "seen" so only
    /// local-only records get written as new.
    private func beginJoin(_ source: SyncSource) {
        joining.insert(source.id)
        let cols = Set(source.collections.map(\.name))
        var changed = [String: Set<String>]()
        var parents = [String: Set<String>]()
        for col in cols {
            let keys = Set(state.doc.collections[col]?.keys.map { $0 } ?? [])
            if !keys.isEmpty { changed[col] = keys }
            if specs[col]?.ordered == true {
                parents[col] = Set(keys.compactMap { state.doc.parent(col, $0) })
            }
        }
        let update = SyncUpdate(doc: state.doc, changed: changed, changedParents: parents, expected: SyncProjection())
        source.apply(update) { [weak self] in
            // Never a sync hop: sources call back from their own queue, and
            // finishJoin re-enters the source (project) synchronously.
            guard let self else { return }
            if DispatchQueue.getSpecific(key: self.queueKey) == true {
                self.finishJoin(source)
            } else {
                self.queue.async { self.finishJoin(source) }
            }
        }
    }

    private func finishJoin(_ source: SyncSource) {
        guard joining.contains(source.id) else { return }
        guard let projection = source.project() else {
            // Not readable yet; try again shortly.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishJoin(source) }
            return
        }
        var seeded = SyncProjection()
        let doc = state.doc
        for (col, records) in projection.records {
            seeded.declare(col)
            for (key, fields) in records where doc.isAlive(col, key) {
                var f = fields
                if specs[col]?.ordered == true {
                    f[SyncReservedField.parent] = doc.value(col, key, SyncReservedField.parent)
                    f[SyncReservedField.order] = doc.value(col, key, SyncReservedField.order)
                }
                seeded[col, key] = f
            }
        }
        for (col, lists) in projection.lists {
            for (parent, items) in lists {
                seeded.lists[col, default: [:]][parent] = items.filter { doc.isAlive(col, $0) && doc.parent(col, $0) == parent }
            }
        }
        state.previous[source.id] = seeded
        joining.remove(source.id)
        markDirty()
        scheduleTick()
    }

    // MARK: - Divergence

    private struct Divergence {
        var keys = [String: Set<String>]()
        var parents = [String: Set<String>]()
        var fieldCount = 0
        var isEmpty: Bool { keys.isEmpty && parents.isEmpty }
    }

    /// Records whose last-seen local value differs from the merged doc.
    private func divergentKeys() -> Divergence {
        var out = Divergence()
        for source in sources {
            guard let prev = state.previous[source.id], !joining.contains(source.id) else { continue }
            for (col, records) in prev.records {
                for (key, fields) in records {
                    if state.doc.isDeleted(col, key) {
                        out.keys[col, default: []].insert(key)
                        out.fieldCount += 1
                        continue
                    }
                    guard state.doc.hasRecord(col, key) else { continue }
                    let docFields = state.doc.collections[col]?[key]?.fields ?? [:]
                    let names = Set(fields.keys).union(docFields.keys).subtracting([SyncReservedField.deleted])
                    for f in names where (fields[f] ?? .null) != (docFields[f]?.v ?? .null) {
                        out.keys[col, default: []].insert(key)
                        out.fieldCount += 1
                        if f == SyncReservedField.parent || f == SyncReservedField.order {
                            if let p = fields[SyncReservedField.parent]?.stringValue { out.parents[col, default: []].insert(p) }
                            if let p = state.doc.parent(col, key) { out.parents[col, default: []].insert(p) }
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Maintenance

    /// Forget everything local (new device id, empty doc). The next round
    /// re-joins from whatever the transport holds.
    public func resetLocalState() {
        onQueue {
            state = SyncEngineState(deviceID: UUID().uuidString)
            joining.removeAll()
            storage.save(state)
            publishStatus()
            scheduleTick()
        }
    }

    /// Treat `sourceID` as never synced: next round re-applies the merged
    /// doc to it and only writes what's local-only afterwards. For when the
    /// source's data was reset outside sync's view.
    public func rejoin(sourceID: String) {
        onQueue {
            state.previous[sourceID] = nil
            markDirty()
        }
    }

    public func clearDebugLog() {
        onQueue {
            state.conflicts.removeAll()
            state.errors.removeAll()
            markDirty()
            publishStatus()
        }
    }

    private func policy(_ col: String) -> SyncMergePolicy {
        specs[col]?.policy ?? LastWriterWins()
    }

    private func logError(_ message: String) {
        // Collapse repeats (e.g. a folder that's offline for an hour).
        if state.errors.last?.message == message {
            state.errors[state.errors.count - 1].at = now()
        } else {
            state.errors.append(SyncLogEntry(at: now(), message: message))
            if state.errors.count > Self.maxErrors { state.errors.removeFirst(state.errors.count - Self.maxErrors) }
        }
        print("[Sync] \(message)")
    }

    private func markDirty() {
        if dirtySince == nil { dirtySince = now() }
    }

    private func saveIfNeeded() {
        guard dirtySince != nil, now().timeIntervalSince(lastSave) > 5 else { return }
        storage.save(state)
        lastSave = now()
        dirtySince = nil
    }

    private func publishStatus(unapplied: Int? = nil) {
        var s = SyncStatus()
        s.running = running
        s.deviceID = state.deviceID
        s.deviceName = deviceName
        s.transport = transport.debugDescription
        s.stats = state.stats
        s.outboxCount = state.outbox.count
        s.devices = state.devices.values.sorted { $0.lastBatchAt > $1.lastBatchAt }
        s.conflicts = state.conflicts.reversed()
        s.errors = state.errors.reversed()
        for col in state.doc.collections.keys { s.recordCounts[col] = state.doc.aliveKeys(col).count }
        s.unappliedFields = unapplied ?? statusSubject.value.unappliedFields
        s.joinedSources = state.previous.keys.sorted()
        statusSubject.send(s)
    }

    private func onQueue<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return block() }
        return queue.sync(execute: block)
    }
}

/// Saves engine state as JSON in a file.
public final class FileSyncEngineStorage: SyncEngineStorage {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> SyncEngineState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SyncEngineState.self, from: data)
        } catch {
            print("[Sync] Couldn't decode engine state, starting fresh: \(error)")
            return nil
        }
    }

    public func save(_ state: SyncEngineState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            print("[Sync] Couldn't save engine state: \(error)")
        }
    }
}

public final class InMemorySyncEngineStorage: SyncEngineStorage {
    public var state: SyncEngineState?
    public init(state: SyncEngineState? = nil) { self.state = state }
    public func load() -> SyncEngineState? { state }
    public func save(_ state: SyncEngineState) { self.state = state }
}
