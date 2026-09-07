import Foundation

enum TabDropDestination: Equatable {
    case ordinaryTabs(window: ID<WindowState>, before: ID<Tab>?) // if before is nil, insert at end
    case favorites(profile: ID<Profile>, before: ID<Tab>?)
    case project(project: ID<Project>, before: ID<Tab>?)
    case space(window: ID<WindowState>, profile: ID<Profile>) // appended to that space's ordinary tabs
}

extension BrowserState {
    func canMove(tab: ID<Tab>, to dest: TabDropDestination) -> Bool {
        guard tabs[tab] != nil else { return false }
        guard let srcWindow = windowContaining(tabId: tab) else { return false }
        guard let destProfile = profile(forTabDropDest: dest) else { return false }

        if case .space = dest {
            // Dropping on a space dot is explicitly a cross-profile move;
            // only a drop on the tab's own space is a no-op.
            return srcWindow.profile != destProfile
        }

        // Return false if we are moving to a different profile
        return srcWindow.profile == destProfile
    }

    func profile(forTabDropDest dest: TabDropDestination) -> ID<Profile>? {
        switch dest {
        case .ordinaryTabs(let window, _):
            return windows[window]?.profile
        case .favorites(let profile, _):
            return profile
        case .project(let project, _):
            return projects[project]?.profile
        case .space(_, let profile):
            return profiles[profile]?.id
        }
    }
    
    mutating func move(tab: ID<Tab>, to dest: TabDropDestination, makeActiveInWindow window: ID<WindowState>?) {
        guard let srcTab = tabs[tab] else { return }
        
        // Find the current location and remove tab from it
        if let srcWindow = windowContaining(tabId: tab) {
            // Remove from active state in previous window if it was active
            if srcWindow.currentTab == tab {
                windows[srcWindow.id]?.currentTab = nil
            }
            
            // Remove tab from its current location
            if let location = location(ofTabId: tab, inWindowId: srcWindow.id) {
                switch location {
                case .ordinaryTabs(let idx):
                    windows[srcWindow.id]?.tabs.remove(at: idx)
                case .project(let projId, let idx):
                    projects[projId]?.tabs.remove(at: idx)
                case .attachedAgent(let idx):
                    windows[srcWindow.id]?.attachedAgentTabs.remove(at: idx)
                case .favorites:
                    // Handle removing from favorites if needed
                    let profileId = srcWindow.profile
                    profiles[profileId]?.manualFavorites.removeAll { $0 == tab }
                    profiles[profileId]?.autoFavorites.removeAll { $0 == tab }
                }
            }
        }
        
        // Insert tab at new location
        switch dest {
        case .ordinaryTabs(let windowId, let beforeTab):
            let insertIndex: Int
            if let beforeTab = beforeTab, let idx = windows[windowId]?.tabs.firstIndex(of: beforeTab) {
                insertIndex = idx
            } else {
                insertIndex = windows[windowId]?.tabs.count ?? 0
            }
            windows[windowId]?.tabs.insert(tab, at: insertIndex)
            
            // Clear baseInfo when moving to ordinary tabs
            modifyTab(id: tab) { tab in
                for i in 0..<tab.panes.count {
                    tab.panes[i]!.baseInfo = nil
                }
            }
            
        case .favorites(let profileId, let beforeTab):
            let insertIndex: Int
            if let beforeTab = beforeTab, let idx = profiles[profileId]?.manualFavorites.firstIndex(of: beforeTab) {
                insertIndex = idx
            } else {
                insertIndex = profiles[profileId]?.manualFavorites.count ?? 0
            }
            profiles[profileId]?.manualFavorites.insert(tab, at: insertIndex)
            // Ensure it's not in auto favorites
            profiles[profileId]?.autoFavorites.removeAll { $0 == tab }
            
            // Set baseInfo to current info when moving to favorites
            modifyTab(id: tab) { tab in
                for i in 0..<tab.panes.count {
                    tab.panes[i]!.baseInfo = tab.panes[i]!.info
                }
            }
            
        case .project(let projectId, let beforeTab):
            let insertIndex: Int
            if let beforeTab = beforeTab, let idx = projects[projectId]?.tabs.firstIndex(of: beforeTab) {
                insertIndex = idx
            } else {
                insertIndex = projects[projectId]?.tabs.count ?? 0
            }
            projects[projectId]?.tabs.insert(tab, at: insertIndex)

        case .space(let windowId, let profileId):
            guard windows[windowId] != nil else { return }
            if windows[windowId]!.perProfileData[profileId] == nil {
                windows[windowId]!.perProfileData[profileId] = .init(tabs: [])
            }
            windows[windowId]!.perProfileData[profileId]!.tabs.append(tab)

            // Clear baseInfo, same as moving to ordinary tabs
            modifyTab(id: tab) { tab in
                for i in 0..<tab.panes.count {
                    tab.panes[i]!.baseInfo = nil
                }
            }
        }

        // Update tab's last active window
        if let windowToActivate = window {
            modifyTab(id: tab) { tab in
                tab.lastActiveInWindow = windowToActivate
            }
            windows[windowToActivate]?.currentTab = tab
        }
    }
}

extension BrowserStore {
    /// Moves a tab into a different space (profile) within the same window.
    /// If the destination profile uses a different website data store, the
    /// tab's live webviews are dropped so they recreate with the right store.
    func move(tab tabID: ID<Tab>, toSpace profileID: ID<Profile>, inWindow windowID: ID<WindowState>) {
        assertOnMainThread()
        let state = model
        let dest = TabDropDestination.space(window: windowID, profile: profileID)
        guard state.canMove(tab: tabID, to: dest) else { return }

        let srcDataStore = state.windowContaining(tabId: tabID).flatMap { state.profiles[$0.profile]?.dataStoreUUID }
        let destDataStore = state.profiles[profileID]?.dataStoreUUID
        let paneIDs = state.tabs[tabID]?.panes.map(\.id) ?? []

        modify { state in
            state.move(tab: tabID, to: dest, makeActiveInWindow: nil)
            let spaceName = state.profiles[profileID]?.title ?? "another space"
            state.addToast(message: "Moved tab to \(spaceName)", icon: "arrowshape.turn.up.right", in: windowID)
        }

        if srcDataStore != destDataStore {
            for paneID in paneIDs {
                unloadWebContent(forId: paneID)
            }
        }
    }
}

extension BrowserState {
    /// Opens a (background) file-browser tab for a file/folder on disk — e.g.
    /// something dropped into the sidebar from Finder — and places it at the
    /// given drop destination (end of the window's ordinary tabs if nil).
    @discardableResult
    mutating func openFileTab(path: String, windowID: ID<WindowState>, at dest: TabDropDestination?) -> ID<Tab> {
        let tab = openTab(url: NativePageKey.fileBrowser(path: path).url, activate: false, windowID: windowID)
        let target = dest ?? .ordinaryTabs(window: windowID, before: nil)
        if canMove(tab: tab.id, to: target) {
            move(tab: tab.id, to: target, makeActiveInWindow: nil)
        }
        return tab.id
    }

    mutating func popTab(id: ID<Tab>) {
        modifyTab(id: id) { $0.animationCount = ($0.animationCount ?? 0) + 1 }
    }
}
