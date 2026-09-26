import Foundation

// Background "cleanup" of stale, low-value tabs. Runs after launch and before
// every AI auto-organize pass. Nothing here is archived: every closed tab is
// either empty, a duplicate of a tab we keep, a leftover from joining a
// meeting, an idle terminal at its prompt, or an agent-opened ghost the user
// never looked at.
//
// Never closed: pinned tabs, any window's current tab, open pip panels, split
// tabs, and panes an agent currently holds a lease on.

private let cleanupLoggingEnabled = true
private func cleanupLog(_ message: String) {
    if cleanupLoggingEnabled { print("🧹 [Cleanup] \(message)") }
}

public enum CleanupReason: String {
    case emptyNewTab
    case duplicate
    case zoomPostJoin
    case meetHomepage
    case idleTerminal
    case unopenedAgentTab
}

public struct CleanupCandidate: Equatable {
    public var tabID: ID<Tab>
    public var paneID: ID<WebContent>
    public var reason: CleanupReason
    public var title: String?
}

extension BrowserState {
    static let cleanupEmptyTabAge: TimeInterval = 2 * 60
    static let cleanupDuplicateAge: TimeInterval = 6 * 60 * 60
    static let cleanupMeetingAge: TimeInterval = 2 * 60 * 60
    static let cleanupTerminalAge: TimeInterval = 6 * 60 * 60
    static let cleanupAgentTabAge: TimeInterval = 6 * 60 * 60

    /// Tabs the background cleanup should close right now.
    func tabsToCleanup(now: Date) -> [CleanupCandidate] {
        let currentTabIDs = Set(windows.values.compactMap(\.currentTab))

        // Single-pane, non-pinned, non-current, non-pip, agent-idle tabs that
        // live in some window (the only ones `_close` can act on).
        var eligible: [(tab: Tab, pane: Pane, age: TimeInterval)] = []
        for tab in tabs.values {
            guard tab.panes.count == 1, let pane = tab.panes.first else { continue }
            if currentTabIDs.contains(tab.id) { continue }
            if tab.isPip && tab.pipOpen == true { continue }
            if let until = pane.agentActiveUntil, until > now { continue }
            if isPinned(tabId: tab.id) { continue }
            if windowContaining(tabId: tab.id) == nil { continue }
            let lastTouched = max(tab.lastAccessed, pane.agentLastUsedAt ?? .distantPast)
            eligible.append((tab, pane, now.timeIntervalSince(lastTouched)))
        }

        // Most-recently-accessed tab per history key, so de-dupe keeps that one.
        var newestByHistoryKey: [String: (tabID: ID<Tab>, lastAccessed: Date)] = [:]
        for tab in tabs.values {
            guard tab.panes.count == 1, let url = tab.panes.first?.info.url, NativePageKey(url: url) == nil else { continue }
            let key = url.historyKey
            if let cur = newestByHistoryKey[key], cur.lastAccessed >= tab.lastAccessed { continue }
            newestByHistoryKey[key] = (tab.id, tab.lastAccessed)
        }

        var out: [CleanupCandidate] = []
        for (tab, pane, age) in eligible {
            guard let reason = cleanupReason(tab: tab, pane: pane, age: age, newestByHistoryKey: newestByHistoryKey) else { continue }
            out.append(CleanupCandidate(tabID: tab.id, paneID: pane.id, reason: reason, title: pane.info.title))
        }
        return out
    }

    private func cleanupReason(tab: Tab, pane: Pane, age: TimeInterval, newestByHistoryKey: [String: (tabID: ID<Tab>, lastAccessed: Date)]) -> CleanupReason? {
        let info = pane.info
        guard let url = info.url else {
            // Empty "new tab". Chat-mode spaces keep blank tabs on purpose.
            if !isChatMode, age > Self.cleanupEmptyTabAge { return .emptyNewTab }
            return nil
        }

        if let native = NativePageKey(url: url) {
            switch native {
            case .terminal(let cwd, _):
                // Idle at the prompt, showing nothing but its cwd as the title.
                let atPrompt = info.terminalForegroundCommand?.nilIfEmpty == nil
                let titleIsJustCwd = info.title?.nilIfEmpty == nil || info.title == NativePageKey.prettyCwd(cwd)
                if atPrompt, titleIsJustCwd, info.badged != true, age > Self.cleanupTerminalAge {
                    return .idleTerminal
                }
            case .agent, .vscode, .fileBrowser:
                break
            }
            return nil
        }

        // Agent-opened ghost tab the user never promoted by opening it.
        if pane.isGhost, age > Self.cleanupAgentTabAge {
            return .unopenedAgentTab
        }

        if url.isZoomPostJoinPage, age > Self.cleanupMeetingAge { return .zoomPostJoin }
        if url.isGoogleMeetHomepage, age > Self.cleanupMeetingAge { return .meetHomepage }

        if age > Self.cleanupDuplicateAge,
           let newest = newestByHistoryKey[url.historyKey],
           newest.tabID != tab.id {
            return .duplicate
        }
        return nil
    }
}

private extension URL {
    /// The page Zoom leaves behind after handing off to the desktop app
    /// ("Click Open zoom.us…"), or after a meeting ends.
    var isZoomPostJoinPage: Bool {
        let host = hostWithoutWWW
        guard host == "zoom.us" || host.hasSuffix(".zoom.us") else { return false }
        let prefixes = ["/j/", "/s/", "/w/", "/wc/", "/join", "/postattendee", "/launch", "/start"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    var isGoogleMeetHomepage: Bool {
        guard hostWithoutWWW == "meet.google.com" else { return false }
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        return p.isEmpty || p == "/landing"
    }
}

extension BrowserStore {
    /// Called once from init: sweep shortly after launch, when the restored
    /// state (and terminal run-state reset) has settled.
    func setupCleanupAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.cleanupTabs(trigger: "launch")
        }
    }

    /// Close stale tabs (see `BrowserState.tabsToCleanup`). Main thread.
    /// Returns the number of tabs closed.
    @discardableResult
    public func cleanupTabs(trigger: String) -> Int {
        assertOnMainThread()
        guard DefaultsKeys.cleanupTabs.boolValue(defaultValue: true) else { return 0 }
        let candidates = model.tabsToCleanup(now: Date())
        if candidates.isEmpty {
            cleanupLog("(\(trigger)) nothing to close")
            return 0
        }
        for c in candidates {
            cleanupLog("(\(trigger)) closing '\(c.title ?? "untitled")' [\(c.reason.rawValue)]")
            close(webContentId: c.paneID, removeIfPinned: false)
        }
        return candidates.count
    }
}
