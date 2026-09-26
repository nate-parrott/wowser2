import Foundation

// A very short, high-level digest of a space's memory, handed to the built-in
// (chat-mode) agent so it knows what the user has been up to without
// querying. It's deliberately tiny: recent pages, recent non-screen events
// in one line each, the open tabs, and how to pull the rest via
// `browser.memory.query`.

extension MemoryStore {

    public struct BriefTab {
        public var tabID: String
        public var paneID: String
        public var title: String
        public var url: String?
        public var isCurrent: Bool
        public init(tabID: String, paneID: String, title: String, url: String?, isCurrent: Bool) {
            self.tabID = tabID; self.paneID = paneID; self.title = title; self.url = url; self.isCurrent = isCurrent
        }
    }

    public struct BriefSpace {
        public var id: String
        public var name: String
        public var tabCount: Int
        public var isCurrent: Bool
        public init(id: String, name: String, tabCount: Int, isCurrent: Bool) {
            self.id = id; self.name = name; self.tabCount = tabCount; self.isCurrent = isCurrent
        }
    }

    /// Markdown-ish text, or nil when memory is off for the scope. Events and
    /// pages come from THIS space; the top-domains list spans every enabled
    /// scope (all spaces) for ambient awareness. Off the main thread except
    /// for the tab/space lists the caller passes in.
    public func brief(scope: UUID, spaceID: String, openTabs: [BriefTab], spaces: [BriefSpace] = [], maxPages: Int = 12, maxEvents: Int = 15, maxDomains: Int = 30) async -> String? {
        guard isEnabled(scope) else { return nil }
        let pageRows = (try? await performRead(scope: scope, sql: """
            SELECT url, title, MAX(ts) AS ts FROM events
            WHERE kind = 'visit' AND page_type = 'web' AND space_id = ? AND url IS NOT NULL
            GROUP BY url ORDER BY ts DESC LIMIT ?
            """, params: [spaceID, maxPages], limit: maxPages)) ?? []
        let eventRows = (try? await performRead(scope: scope, sql: """
            SELECT kind, page_type, title, domain, substr(text, 1, 90) AS snippet, ts FROM events
            WHERE space_id = ? AND kind != 'screen'
            ORDER BY id DESC LIMIT ?
            """, params: [spaceID, maxEvents], limit: maxEvents)) ?? []
        let overview: String = (try? await perform(scope: scope) { db in
            (try db.scalar("SELECT value FROM meta WHERE key = 'overview'")) as? String ?? ""
        }) ?? ""
        // Top domains over the last 30 days, merged across every enabled scope.
        let since = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
        var domainCounts: [String: Int] = [:]
        for s in enabledScopeIDs {
            let rows = (try? await performRead(scope: s, sql: """
                SELECT domain, COUNT(*) AS n FROM events
                WHERE kind = 'visit' AND domain IS NOT NULL AND ts > ?
                GROUP BY domain ORDER BY n DESC LIMIT ?
                """, params: [since, maxDomains * 2], limit: maxDomains * 2)) ?? []
            for r in rows {
                guard let d = r["domain"] as? String, let n = r["n"] as? Int64 else { continue }
                domainCounts[d, default: 0] += Int(n)
            }
        }
        let topDomains = domainCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxDomains)

        var out: [String] = ["[Memory brief — scope \(scope.uuidString), space \(spaceID)]"]
        if let head = Self.overviewHead(overview, maxChars: 600) {
            out.append("Overview (excerpt): " + head)
        }
        if !spaces.isEmpty {
            out.append("Spaces: " + spaces.map { "\($0.isCurrent ? "[current] " : "")\(Self.short($0.name, 40)) (id \($0.id), \($0.tabCount) tabs)" }.joined(separator: "; "))
        }
        if !openTabs.isEmpty {
            out.append("Open tabs in this space:")
            for t in openTabs.prefix(25) {
                out.append("- \(t.isCurrent ? "[current] " : "")\(Self.short(t.title, 70))\(t.url.map { " — " + Self.short($0, 100) } ?? "") (tab \(t.paneID))")
            }
        }
        if !pageRows.isEmpty {
            out.append("Recently visited pages (newest first):")
            for r in pageRows {
                let title = Self.short(r["title"] as? String ?? "", 70)
                let url = Self.short(r["url"] as? String ?? "", 100)
                out.append("- \(title.isEmpty ? url : title + " — " + url) (\(Self.ago(r["ts"])))")
            }
        }
        if !eventRows.isEmpty {
            out.append("Recent events (newest first; screen captures omitted):")
            for r in eventRows {
                let kind = r["kind"] as? String ?? "?"
                let place = (r["domain"] as? String)?.nilIfEmpty ?? Self.short(r["title"] as? String ?? (r["page_type"] as? String ?? ""), 40)
                let snippet = Self.short((r["snippet"] as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ "), 90)
                out.append("- \(Self.ago(r["ts"])) \(kind)\(place.isEmpty ? "" : " @ " + place)\(snippet.isEmpty ? "" : ": " + snippet)")
            }
        }
        if !topDomains.isEmpty {
            out.append("Top sites, all spaces, last 30 days: " + topDomains.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
        }
        if pageRows.isEmpty && eventRows.isEmpty {
            out.append("(No events recorded for this space yet.)")
        }
        out.append("""
        More: `await browser.memory.schema()` explains the tables; `await browser.memory.query({ scope: '\(scope.uuidString)', sql: "SELECT … FROM events WHERE space_id = '\(spaceID)' … LIMIT 50" })` runs read-only SQL (FTS via events_fts); drop the space_id filter for other spaces. `browser.memory.overview()` returns the full overview.
        [End of memory brief]
        """)
        return out.joined(separator: "\n")
    }

    static func overviewHead(_ text: String, maxChars: Int) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let flat = t.replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
        return flat.count <= maxChars ? flat : String(flat.prefix(maxChars)) + "…"
    }

    static func short(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }

    /// "3m ago", "2h ago", "5d ago" from a unix-seconds column value.
    static func ago(_ value: Any?, now: Date = Date()) -> String {
        let ts: Double
        switch value {
        case let d as Double: ts = d
        case let i as Int64: ts = Double(i)
        default: return "?"
        }
        let secs = max(0, now.timeIntervalSince1970 - ts)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }
}
