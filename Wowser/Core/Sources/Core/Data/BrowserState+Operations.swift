import Foundation

extension BrowserState {
    var activeWindow: WindowState? {
        windows.values.max(by: { ($0.lastActive ?? .distantPast) < ($1.lastActive ?? .distantPast) })
    }
    
    mutating func getOrCreateActiveWindow() -> WindowState {
        if let activeWindow {
            return activeWindow
        }
        return newWindow()
    }
    
    var defaultProfileForNewWindows: Profile! {
        if let pid = activeWindow?.profile, let prof = profiles[pid] {
            return prof
        }
        return profiles.values.first
    }
    
    mutating func newWindow() -> WindowState {
        let win = WindowState(id: .assign(), profile: defaultProfileForNewWindows.id, lastActive: Date())
        self.windows[win.id] = win
        return win
    }
    
    @discardableResult
    mutating func openTab(url: URL, activate: Bool = true) -> Tab {
        let win = getOrCreateActiveWindow()
        let insertionLocation = insertionIndex(window: win.id, spawningTabId: win.currentTab)
//        let tab = Tab(id: .assign(), info: .init(url: url), lastAccessed: Date(), aiLabel: nil)
        let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init(url: url))])
        insertTab(tab, location: insertionLocation, inWindow: win.id)
//        windows[win.id]!.tabs.insert(tab.id, at: idx)
        if activate {
            self.activate(tabId: tab.id, in: win.id)
        }
        return tab
    }
    
//    mutating func insert(tabId: ID<Tab>, inWindow window: ID<WindowState>, location: SidebarLocation) {
//    }
    
    mutating func activate(tabId id: ID<Tab>?, in window: ID<WindowState>) {
        if let old = windows[window]?.currentTab {
            modifyTab(id: old) { tab in
                tab.lastAccessed = Date(timeIntervalSinceNow: -0.1) // to break ties when we set the NEW tab to be active NOW
            }
        }
        windows[window]?.currentTab = id
        if let id {
            modifyTab(id: id) { tab in
                tab.lastAccessed = Date()
            }
        }
    }
    
    func insertionIndex(window: ID<WindowState>, spawningTabId: ID<Tab>?) -> SidebarLocation {
        guard let win = windows[window] else { return .ordinaryTabs(0) }
        if let spawningTabId, let loc = location(ofTabId: spawningTabId, inWindowId: window) {
            switch loc {
            case .favorites:
                return .ordinaryTabs(win.tabs.count)
            case .ordinaryTabs(let idx):
                return .ordinaryTabs(idx + 1) // TODO: insert below siblings from same parent
            case .project(let id, let idx):
                return .project(id, idx + 1)
            }
        }
        if let proj = win.focusedOnProject {
            let projTabCounts = projects[proj]?.tabs.count ?? 0
            return .project(proj, projTabCounts)
        }
        return .ordinaryTabs(win.tabs.count)
    }
    
    func location(ofTabId tabId: ID<Tab>, inWindowId windowId: ID<WindowState>) -> SidebarLocation? {
        guard let win = windows[windowId] else { return nil }
        if let idx = win.tabs.firstIndex(of: tabId) {
            return .ordinaryTabs(idx)
        }
        let faves = favorites(profileId: win.profile)
        if let idx = faves.firstIndex(of: tabId) {
            return .favorites(idx)
        }
        return nil
    }
    
    func favorites(profileId: ID<Profile>) -> [ID<Tab>] {
        if let prof = profiles[profileId] {
            return prof.manualFavorites + prof.autoFavorites
        }
        return []
    }
    
    // Call the method on BrowserStore instead
    mutating func _close(webContentId id: ID<WebContent>, removeIfPinned: Bool) {
        guard let tabId = self.paneToTabMapping[id],
              let tab = tabs[tabId],
              let winId = self.windowContaining(tabId: tabId)?.id
        else { return }
                
        func reselect() {
            let selectNext = tabToSelectAfterClosing(tabId: tabId)
            activate(tabId: selectNext, in: winId)
        }
        
        func resetToBase() {
            modifyPaneAndTab(forWebContentId: id) { pane, tab in
                if let base = pane.baseInfo {
                    pane.info = base
                }
            }
        }
        
        func remove() {
            _removeTab_unsafe_doesntCloseWebContent(tabId: tabId)
        }
        
        let isPinned = self.isPinned(tabId: tabId)
        
        if isPinned && !removeIfPinned {
            resetToBase()
            reselect()
            return
        }
        
        if tab.panes.count > 1 {
            // Don't close tab, just pane
            _removePane_unsafe(id: id)
        } else {
            remove()
            reselect()
        }
    }
    
    func tabToSelectAfterClosing(tabId id: ID<Tab>) -> ID<Tab>? {
        guard let win = windowContaining(tabId: id) else {
            return nil
        }
        if let loc = location(ofTabId: id, inWindowId: win.id) {
            switch loc {
            case .favorites:
                return nil
            case .ordinaryTabs(let idx):
                return idx == 0 ? win.tabs.get(idx + 1) : win.tabs.get(idx - 1)
            case .project(let projectId, let idx):
                let projectTabs = projects[projectId]?.tabs ?? []
                return idx == 0 ? projectTabs.get(idx + 1) : projectTabs.get(idx - 1)
            }
        }
        return win.tabs.filter({ $0 != id }).max { tab1, tab2 in
            (self.tabs[tab1]?.lastAccessed ?? Date.distantPast) < (self.tabs[tab2]?.lastAccessed ?? Date.distantPast)
        }
    }
    
    func windowContaining(tabId id: ID<Tab>) -> WindowState? {
        for window in windowsMostRecentFirst {
            if window.tabs.contains(id) {
                return window
            }
            if favorites(profileId: window.profile).contains(id) {
                return window
            }
        }
        return nil
    }
    
    var windowsMostRecentFirst: [WindowState] {
        windows.values.sorted { w0, w1 in
            (w0.lastActive ?? Date.distantPast) > (w1.lastActive ?? Date.distantPast)
        }
    }
}

enum SidebarLocation: Equatable {
    case favorites(Int)
    case ordinaryTabs(Int)
    case project(ID<Project>, Int)
}

extension BrowserState {
    /// Checks if a tab is pinned (favorite) based on its sidebar location
    /// - Parameters:
    ///   - tabId: The ID of the tab to check
    /// - Returns: Boolean indicating if the tab is in the favorites location
    public func isPinned(tabId: ID<Tab>) -> Bool {
        if let window = windowContaining(tabId: tabId), 
           let location = location(ofTabId: tabId, inWindowId: window.id),
           case .favorites = location {
            return true
        }
        return false
    }
}
