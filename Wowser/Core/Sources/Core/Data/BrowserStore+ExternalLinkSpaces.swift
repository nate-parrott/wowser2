import Foundation
import ChatToys

// Links handed to us by other apps open in the current space right away, then
// an LLM picks the space they fit best (by space names, open tabs, and each
// space's recently visited domains). If that differs from the current space
// the tab is moved there and the window follows it — unless the user has
// already moved on to another tab, in which case the tab moves quietly.
// Off via DefaultsKeys.sortExternalLinksIntoSpaces; skipped with one space.

extension BrowserState {
    static let recentDomainsPerSpace = 20

    /// Push `url`'s host to the front of its space's `recentDomains`.
    mutating func noteVisitedDomain(url: URL, forWebContentId id: ID<WebContent>) {
        guard let host = url.hostWithoutWWW.nilIfEmpty, url.scheme?.hasPrefix("http") == true,
              let profileID = profile(forWebContentId: id)?.id else { return }
        var domains = profiles[profileID]?.recentDomains ?? []
        domains.removeAll { $0 == host }
        domains.insert(host, at: 0)
        profiles[profileID]?.recentDomains = Array(domains.prefix(Self.recentDomainsPerSpace))
    }

    struct SpaceForClassification {
        var id: ID<Profile>
        var name: String
        var recentDomains: [String]
        var openTabs: [String] // "title — host", most recently used first
    }

    /// Visible spaces with the context the classifier prompt needs, as seen
    /// from `windowID` (open tabs come from every window, this one first).
    func spacesForClassification(windowID: ID<WindowState>, maxTabsPerSpace: Int = 12) -> [SpaceForClassification] {
        visibleProfiles.map { profile in
            let spaceTabs: [Tab] = sharedSidebarTabIDs(windowID: windowID, profileID: profile.id).compactMap { self.tabs[$0] }
            let recent: [Tab] = Array(spaceTabs.sorted(by: { $0.lastAccessed > $1.lastAccessed }).prefix(maxTabsPerSpace))
            var tabs = [String]()
            for tab in recent {
                guard let pane = tab.panes.first, let url = pane.info.url, url.scheme?.hasPrefix("http") == true else { continue }
                let title: String? = tab.customTitle?.nilIfEmpty ?? pane.info.title?.nilIfEmpty
                let parts: [String] = [title, url.hostWithoutWWW].compactMap { $0 }
                tabs.append(parts.joined(separator: " — "))
            }
            return SpaceForClassification(id: profile.id, name: profile.displayName, recentDomains: profile.recentDomains ?? [], openTabs: tabs)
        }
    }
}

extension BrowserStore {
    /// Entry point for URLs from other apps (AppDelegate).
    public func openExternalURL(_ url: URL) {
        assertOnMainThread()
        var opened: (tab: ID<Tab>, pane: ID<WebContent>, window: ID<WindowState>)?
        modify { state in
            let tab = state.openTab(url: url, activate: true)
            guard let window = state.windowContaining(tabId: tab.id), let pane = tab.panes.first else { return }
            opened = (tab.id, pane.id, window.id)
        }
        guard let opened,
              DefaultsKeys.sortExternalLinksIntoSpaces.boolValue(defaultValue: true),
              url.scheme?.hasPrefix("http") == true,
              model.visibleProfiles.count > 1,
              LLMs.current(json: true) != nil
        else { return }

        modify { state in
            state.modifyPaneAndTab(forWebContentId: opened.pane) { pane, _ in pane.pickingSpace = true }
        }
        Task { @MainActor in
            defer {
                modify { state in
                    state.modifyPaneAndTab(forWebContentId: opened.pane) { pane, _ in pane.pickingSpace = nil }
                }
            }
            do {
                if let dest = try await classifySpace(for: url, windowID: opened.window) {
                    moveExternalTab(opened.tab, toSpace: dest, inWindow: opened.window)
                }
            } catch {
                print("[🗂️ External link] Classification failed: \(error)")
            }
        }
    }

    /// The space the LLM thinks `url` belongs in, or nil to leave it put.
    private func classifySpace(for url: URL, windowID: ID<WindowState>) async throws -> ID<Profile>? {
        let (spaces, currentID) = await readAsync { state in
            (state.spacesForClassification(windowID: windowID), state.windows[windowID]?.profile)
        }
        guard spaces.count > 1 else { return nil }
        let currentIdx = spaces.firstIndex(where: { $0.id == currentID }).map { $0 + 1 }

        var lines = [String]()
        lines.append("A link was just opened from another app. Pick the browser space (workspace) it belongs in.")
        lines.append("")
        lines.append("Link: \(url.absoluteString)")
        lines.append("")
        lines.append("Spaces:")
        for (i, space) in spaces.enumerated() {
            lines.append("\(i + 1). \"\(space.name)\"" + (i + 1 == currentIdx ? " (current space)" : ""))
            if !space.recentDomains.isEmpty {
                lines.append("   Recently visited: " + space.recentDomains.joined(separator: ", "))
            }
            if !space.openTabs.isEmpty {
                lines.append("   Open tabs:")
                for tab in space.openTabs { lines.append("     - \(tab)") }
            }
        }
        lines.append("")
        lines.append("Choose the space whose name, recent sites, or open tabs best match this link's domain and likely topic. Only leave the current space if another space is a clearly better fit; when unsure, keep the current space.")
        lines.append("Respond with JSON: {\"space\": <number>, \"reason\": \"<short>\"}")

        struct Response: Codable {
            var space: Int
            var reason: String?
        }
        let resp = try await LLMs.currentOrThrow(json: true).completeJSONObject(
            prompt: [LLMMessage(role: .user, content: lines.joined(separator: "\n"))],
            type: Response.self
        )
        print("[🗂️ External link] \(url.hostWithoutWWW) → space \(resp.space): \(resp.reason ?? "")")
        guard spaces.indices.contains(resp.space - 1) else { return nil }
        return spaces[resp.space - 1].id
    }

    /// Move the tab to `profileID`. If the user is still looking at it, the
    /// window switches to that space with the tab active; otherwise the tab
    /// moves without disturbing them. A cross-datastore move drops the live
    /// webview so the page reloads with the destination space's cookies.
    private func moveExternalTab(_ tabID: ID<Tab>, toSpace profileID: ID<Profile>, inWindow windowID: ID<WindowState>) {
        assertOnMainThread()
        let state = model
        guard let window = state.windows[windowID], window.profile != profileID,
              state.windowContaining(tabId: tabID)?.id == windowID,
              state.canMove(tab: tabID, to: .space(window: windowID, profile: profileID)) else { return }
        let userStillOnTab = window.currentTab == tabID
        let srcDataStore = state.profiles[window.profile]?.dataStoreUUID
        let destDataStore = state.profiles[profileID]?.dataStoreUUID
        let paneIDs = state.tabs[tabID]?.panes.map(\.id) ?? []

        modify { state in
            state.move(tab: tabID, to: .space(window: windowID, profile: profileID), makeActiveInWindow: nil)
            if userStillOnTab {
                state.windows[windowID]?.profile = profileID
                state.activate(tabId: tabID, in: windowID)
            }
            let spaceName = state.profiles[profileID]?.displayName ?? "another space"
            state.addToast(message: "Opened in \(spaceName)", icon: "arrowshape.turn.up.right", in: windowID)
        }
        if srcDataStore != destDataStore {
            for paneID in paneIDs { unloadWebContent(forId: paneID) }
        }
    }
}
