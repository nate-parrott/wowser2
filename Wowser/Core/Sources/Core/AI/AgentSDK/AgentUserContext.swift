import Foundation

// The "about the user" block appended to every browser agent's system prompt:
// the user's autofill identity, their memory overview, spaces, top sites, how
// much the memory log holds, and the page they're on — each with the BrowserJS
// call that reads the full/live version.

enum AgentUserContext {
    /// Built fresh each time an agent starts. Safe to call from any actor.
    static func section() async -> String? {
        let snap = await MainActor.run { Snapshot(state: BrowserStore.shared.model) }
        var parts: [String] = []
        if let identity = await AutofillStore.agentIdentitySection() {
            parts.append(identity)
        }
        parts.append(snap.browserSection)
        if let memory = await memorySection(scope: snap.scope) {
            parts.append(memory)
        }
        return parts.joined(separator: "\n\n")
    }

    private struct Snapshot {
        struct Space { var id: String; var name: String; var tabCount: Int; var isCurrent: Bool }
        var spaces: [Space] = []
        var hiddenSpaceCount = 0
        var currentTab: (id: String, title: String, url: String?)?
        var scope: UUID?

        init(state: BrowserState) {
            let window = state.activeWindow
            spaces = state.visibleProfiles.map { p in
                Space(id: p.id.raw, name: p.displayName, tabCount: window?.perProfileData[p.id]?.tabs.count ?? 0, isCurrent: p.id == window?.profile)
            }
            hiddenSpaceCount = state.hiddenProfiles.count
            if let window, let tabID = window.currentTab, let tab = state.tabs[tabID], let pane = tab.focusedPane ?? tab.panes.first {
                currentTab = (pane.id.raw, tab.appearance().title, pane.info.url?.absoluteString)
            }
            scope = window.flatMap { state.profiles[$0.profile]?.dataStoreUUID }
        }

        var browserSection: String {
            var lines = ["## The user's browser (when you started)"]
            lines.append("Spaces: " + spaces.map { "\($0.isCurrent ? "[current] " : "")\(MemoryStore.short($0.name, 40)) (id \($0.id), \($0.tabCount) tabs)" }.joined(separator: "; ")
                + (hiddenSpaceCount > 0 ? "; plus \(hiddenSpaceCount) hidden" : ""))
            if let currentTab {
                lines.append("Current page: \(MemoryStore.short(currentTab.title, 80))\(currentTab.url.map { " — " + MemoryStore.short($0, 150) } ?? "") (tab id \(currentTab.id))")
            }
            lines.append("Live versions: `browser.spaces.list()`, `browser.tabs.list({ spaceId })`, `browser.content.read(tabId, { as: 'markdown' })`.")
            return lines.joined(separator: "\n")
        }
    }

    /// Memory overview, log size and top sites; nil when memory is off.
    private static func memorySection(scope: UUID?) async -> String? {
        let store = MemoryStore.shared
        guard let scope, store.isEnabled(scope) else { return nil }
        let overview: String = (try? await store.perform(scope: scope) { db in
            (try db.scalar("SELECT value FROM meta WHERE key = 'overview'")) as? String ?? ""
        }) ?? ""
        let since = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
        let kindRows = (try? await store.performRead(scope: scope, sql: """
            SELECT kind, COUNT(*) AS n FROM events WHERE ts > ? GROUP BY kind ORDER BY n DESC
            """, params: [since], limit: 30)) ?? []
        let total: Int64 = (try? await store.perform(scope: scope) { db in
            (try db.scalar("SELECT COUNT(*) FROM events")) as? Int64 ?? 0
        }) ?? 0
        let topDomains = await store.topDomains(limit: 25)

        var lines = ["## Memory (the browser's log of what the user does)"]
        let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("Overview of the user, written from the log:\n\"\"\"\n\(MemoryStore.short(trimmed, 6000))\n\"\"\"")
        }
        let kinds = kindRows.compactMap { r -> String? in
            guard let k = r["kind"] as? String, let n = r["n"] as? Int64 else { return nil }
            return "\(n) \(k)"
        }
        lines.append("Log size: \(total) events total" + (kinds.isEmpty ? "." : "; last 30 days: " + kinds.joined(separator: ", ") + "."))
        if !topDomains.isEmpty {
            lines.append("Top sites, all spaces, last 30 days: " + topDomains.map { "\($0.domain) (\($0.visits))" }.joined(separator: ", "))
        }
        lines.append("""
        When the user refers to something they did, saw or typed ("that article from yesterday"), look it up: \
        `await browser.memory.schema()` explains the tables; `await browser.memory.query({ scope: '\(scope.uuidString)', sql: 'SELECT … LIMIT 50' })` \
        runs read-only SQL (full-text search via events_fts); `browser.memory.overview()` returns the overview.
        """)
        return lines.joined(separator: "\n")
    }
}
