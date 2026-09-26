import Foundation

// MARK: - Agent tabs attached to the omnibox
//
// When the user asks the agent something from the address bar, the agent's
// chat tab doesn't appear in the sidebar right away. Instead it lives in a
// hidden per-window list (`WindowState.attachedAgentTabs`) and the omnibox
// shows an "agent is working" indicator in place of the URL. The tab is
// restored to the sidebar ("detached") as soon as anything activates it —
// the agent focusing itself via BrowserJS, the user clicking the indicator,
// or the agent finishing with something to show.

public extension BrowserState {
    /// Is this tab currently hidden behind a window's omnibox?
    func isAttachedAgentTab(_ tabID: ID<Tab>) -> Bool {
        windows.values.contains { $0.attachedAgentTabs.contains(tabID) }
    }

    /// Adds a tab to the window's hidden attached-agent list (tail).
    mutating func attachAgentTab(_ tab: Tab, toWindow windowID: ID<WindowState>) {
        var tab = tab
        // Without this a never-activated tab fails the validLiveWebContentIds
        // check and gets its WebContent evicted.
        tab.lastActiveInWindow = windowID
        let count = windows[windowID]?.attachedAgentTabs.count ?? 0
        insertTab(tab, location: .attachedAgent(count), inWindow: windowID)
    }

    /// Moves an attached agent tab back into the sidebar's ordinary tab list,
    /// right after the window's current tab. No-op if the tab isn't attached.
    mutating func detachAgentTab(tabID: ID<Tab>, inWindow windowID: ID<WindowState>) {
        guard let idx = windows[windowID]?.attachedAgentTabs.firstIndex(of: tabID) else { return }
        windows[windowID]?.attachedAgentTabs.remove(at: idx)
        let location = insertionIndex(window: windowID, spawningTabId: windows[windowID]?.currentTab)
        switch location {
        case .ordinaryTabs(let i):
            windows[windowID]?.tabs.insert(tabID, at: i)
        case .project(let projID, let i):
            projects[projID]?.tabs.insert(tabID, at: i)
        case .favorites, .attachedAgent, .folder:
            windows[windowID]?.tabs.append(tabID)
        }
    }

    /// What the omnibox should show for the agents attached to this window,
    /// or nil when none of them is currently working (an attached agent that
    /// finished either reveals itself or closes — see AgentChatSession).
    func attachedAgentStatus(windowID: ID<WindowState>) -> AttachedAgentStatus? {
        guard let win = windows[windowID] else { return nil }
        let entries: [AttachedAgentStatus.Entry] = win.attachedAgentTabs.compactMap { tabID in
            guard let tab = tabs[tabID], let pane = tab.panes.first,
                  let url = pane.info.url, let key = NativePageKey(url: url), case .agent(let agentKey, let query) = key
            else { return nil }
            return AttachedAgentStatus.Entry(
                tabID: tabID,
                agentKey: agentKey,
                query: query ?? "",
                working: pane.info.agentIsWorking ?? false,
                detail: pane.info.agentStatusDetail
            )
        }.filter(\.working)
        guard !entries.isEmpty else { return nil }
        return AttachedAgentStatus(entries: entries)
    }
}

public struct AttachedAgentStatus: Equatable {
    public struct Entry: Equatable {
        public var tabID: ID<Tab>
        public var agentKey: String
        public var query: String
        public var working: Bool
        public var detail: String?
    }
    public var entries: [Entry]

    /// The most recently attached agent — the one the indicator describes.
    public var primary: Entry { entries.last! }
    public var othersCount: Int { entries.count - 1 }

    public var headline: String {
        primary.detail?.nilIfEmpty ?? "Agent is working…"
    }
}
