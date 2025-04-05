import Foundation

enum TabDropDestination: Equatable {
    case ordinaryTabs(window: ID<WindowState>, before: ID<Tab>?) // if before is nil, insert at end
    case favorites(profile: ID<Profile>, before: ID<Tab>?)
    case project(project: ID<Project>, before: ID<Tab>?)
}

extension BrowserState {
    func canMove(tab: ID<Tab>, to dest: TabDropDestination) -> Bool {
        guard let srcTab = tabs[tab] else { return false }
        guard let srcWindow = windowContaining(tabId: tab) else { return false }
        guard let destProfile = profile(forTabDropDest: dest) else { return false }
        
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
