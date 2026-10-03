import Foundation

extension BrowserState {
    // Toast related operations
    public mutating func addToast(message: String, icon: String, in windowID: ID<WindowState>) {
        let toast = Toast(message: message, icon: icon)
        windows[windowID]?.toasts.append(toast)
    }

    public mutating func addToast(_ toast: Toast, in windowID: ID<WindowState>) {
        windows[windowID]?.toasts.append(toast)
    }
    
    public mutating func removeToast(id: UUID, in windowID: ID<WindowState>) {
        windows[windowID]?.toasts.removeAll(where: { $0.id == id })
    }
    
    mutating func removeFirstToast(in windowID: ID<WindowState>) {
        if windows[windowID]?.toasts.isEmpty == false {
            windows[windowID]?.toasts.removeFirst()
        }
    }
    
    // Create a new profile with a unique ID and UUID for its data store.
    // If `sharingLoginsWith` is provided and exists, the new profile reuses
    // that profile's `dataStoreUUID` so they share cookies/logins. Otherwise
    // the new profile gets a fresh UUID (isolated).
    public mutating func createNewProfile(sharingLoginsWith sourceProfileID: ID<Profile>? = nil) -> ID<Profile> {
        let id = ID<Profile>.assign()
        let dataStoreUUID: UUID
        if let sourceProfileID, let source = profiles[sourceProfileID] {
            dataStoreUUID = source.dataStoreUUID
        } else {
            dataStoreUUID = UUID()
        }
        let newCreationOrder: Int = (profiles.values.map({ $0.creationOrder }).max() ?? 0) + 1
        let profile = Profile(id: id, dataStoreUUID: dataStoreUUID, creationOrder: newCreationOrder)
        profiles[id] = profile
        return id
    }

    // Creates a profile named after the given folder, pre-pinned with VS Code,
    // terminal and file-browser tabs pointed at that folder.
    public mutating func createNewProfile(forFolderPath folderPath: String, sharingLoginsWith sourceProfileID: ID<Profile>? = nil) -> ID<Profile> {
        let id = createNewProfile(sharingLoginsWith: sourceProfileID)
        attachFolder(path: folderPath, toProfile: id)
        return id
    }

    /// The "core" native tabs pinned for a space's folder.
    static func coreFolderKeys(_ folderPath: String) -> [NativePageKey] {
        [
            .vscode(folder: folderPath),
            .terminal(cwd: folderPath),
            .fileBrowser(path: folderPath),
        ]
    }

    /// Attaches `path` to the profile (replacing any previous folder). Pinned
    /// native tabs that pointed at the previous folder are re-pointed at the
    /// new one; any of the core kinds (VS Code / terminal / files) that aren't
    /// pinned yet get added. Names the space after the folder if it has no
    /// title yet.
    public mutating func attachFolder(path folderPath: String, toProfile profileID: ID<Profile>) {
        guard var profile = profiles[profileID] else { return }
        let oldPath = profile.folderPath
        profile.folderPath = folderPath
        if profile.title?.nilIfEmpty == nil {
            profile.title = (folderPath as NSString).lastPathComponent
        }
        profiles[profileID] = profile

        for key in BrowserState.coreFolderKeys(folderPath) {
            // An existing pinned tab of this kind on the old folder → re-point it.
            let existing: ID<Tab>? = oldPath == nil ? nil : profile.manualFavorites.first { tabID in
                guard let tab = tabs[tabID], tab.panes.count == 1, let pane = tab.panes.first,
                      let url = pane.baseInfo?.url ?? pane.info.url,
                      let k = NativePageKey(url: url) else { return false }
                return k.kindString == key.kindString && k.folderPath == oldPath
            }
            if let existing, let paneID = tabs[existing]?.panes.first?.id {
                modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
                    pane.info = .init(url: key.url)
                    pane.baseInfo = pane.info
                }
            } else {
                let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init(url: key.url))])
                insertTab(tab, intoProfileFavoritesAtIndex: profiles[profileID]?.manualFavorites.count ?? 0, profile: profileID)
            }
        }
    }

    /// Reorders profiles by moving `movingID` to `targetID`'s position.
    /// Rewrites `creationOrder` for all profiles (hidden ones keep their relative order).
    public mutating func moveProfile(_ movingID: ID<Profile>, toPositionOf targetID: ID<Profile>) {
        guard movingID != targetID, profiles[movingID] != nil, profiles[targetID] != nil else { return }
        var ordered = profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }).map(\.id)
        guard let fromIdx = ordered.firstIndex(of: movingID) else { return }
        ordered.remove(at: fromIdx)
        guard let toIdx = ordered.firstIndex(of: targetID) else { return }
        // Dragging rightward lands after the target; leftward lands before it.
        ordered.insert(movingID, at: fromIdx <= toIdx ? toIdx + 1 : toIdx)
        for (idx, id) in ordered.enumerated() {
            profiles[id]?.creationOrder = idx
        }
    }

    // MARK: - Hiding profiles

    /// Profiles the user can currently see, in creation order.
    public var visibleProfiles: [Profile] {
        profiles.values.filter({ !$0.isHidden }).sorted(by: { $0.creationOrder < $1.creationOrder })
    }

    public var hiddenProfiles: [Profile] {
        profiles.values.filter({ $0.isHidden }).sorted(by: { $0.creationOrder < $1.creationOrder })
    }

    /// We never let the user hide their way down to zero visible profiles.
    public func canHideProfile(_ id: ID<Profile>) -> Bool {
        profiles[id]?.isHidden == false && visibleProfiles.count > 1
    }

    /// Hides a profile and moves any window sitting on it to another visible profile.
    /// Tabs and per-profile data are left intact so unhiding is lossless.
    public mutating func hideProfile(_ id: ID<Profile>) {
        guard canHideProfile(id) else { return }
        profiles[id]?.hidden = true
        guard let fallback = visibleProfiles.first?.id else { return }
        for window in windows.values where window.profile == id {
            windows[window.id]?.profile = fallback
        }
    }

    public mutating func unhideProfile(_ id: ID<Profile>) {
        profiles[id]?.hidden = false
    }

    /// Removes a profile and all of its tabs, moving any window sitting on it
    /// to another profile. Never deletes the last remaining profile.
    public mutating func deleteProfile(_ id: ID<Profile>) {
        guard profiles.count > 1, profiles[id] != nil else { return }
        for window in windows.values {
            for tabID in window.perProfileData[id]?.tabs ?? [] {
                _removeTab_unsafe_doesntCloseWebContent(tabId: tabID)
            }
            if window.profile == id {
                windows[window.id]?.profile = profiles.values.first(where: { $0.id != id })?.id ?? .defaultProfile
            }
            windows[window.id]?.perProfileData.removeValue(forKey: id)
        }
        profiles.removeValue(forKey: id)
    }

    /// Records `path` as the space's folder if it doesn't have one yet. Unlike
    /// `attachFolder`, this doesn't pin tabs or rename the space; it's used
    /// when the user opens a native tab in a folder from the "…" menu.
    public mutating func setFolderIfMissing(path: String, forProfile id: ID<Profile>) {
        guard let profile = profiles[id], profile.folderPath?.nilIfEmpty == nil else { return }
        profiles[id]?.folderPath = path
    }

    /// Moves a tab's pane into another tab's split view
    /// - Parameters:
    ///   - sourceTabId: The ID of the tab containing the pane to be moved
    ///   - sourcePaneId: The ID of the pane to be moved
    ///   - destinationTabId: The ID of the tab to which the pane will be added
    ///   - activatePane: Whether to make the moved pane the active one in its new tab
    /// - Returns: True if the operation was successful, false otherwise
    @discardableResult
    public mutating func moveToSplitView(
        sourceTabId: ID<Tab>, 
        sourcePaneId: ID<WebContent>,
        destinationTabId: ID<Tab>,
        activatePane: Bool = true
    ) -> Bool {
        // Verify both tabs exist and the source pane exists in the source tab
        guard let sourceTab = tabs[sourceTabId],
              let destinationTab = tabs[destinationTabId],
              let sourcePane = sourceTab.panes.first(where: { $0.id == sourcePaneId }) else {
            return false
        }
        
        // Don't allow moving to the same tab
        if sourceTabId == destinationTabId {
            return false
        }
        
        // Remove the pane from the source tab
        modifyTab(id: sourceTabId) { tab in
            tab.panes.remove(id: sourcePaneId)
        }
        
        // Add the pane to the destination tab
        modifyTab(id: destinationTabId) { tab in
            tab.panes.append(sourcePane)
            
            // Activate the pane if requested
            if activatePane {
                tab.focusedPaneIdx = tab.panes.count - 1
            }
        }
        
        // If the source tab has no more panes, remove it completely
        if let tab = tabs[sourceTabId], tab.panes.isEmpty {
            _removeTab_unsafe_doesntCloseWebContent(tabId: sourceTabId)
        }
        
//        // Update pane-to-tab mapping for the moved pane
//        paneToTabMapping[sourcePaneId] = destinationTabId
        
        return true
    }
    
    /// Moves all panes from one tab to another tab's split view
    /// - Parameters:
    ///   - sourceTabId: The ID of the tab containing the panes to be moved
    ///   - destinationTabId: The ID of the tab to which the panes will be added
    ///   - activateLast: Whether to make the last moved pane the active one in its new tab
    /// - Returns: True if the operation was successful, false otherwise
    @discardableResult
    public mutating func moveAllPanesToSplitView(
        sourceTabId: ID<Tab>,
        destinationTabId: ID<Tab>,
        activateLast: Bool = true
    ) -> Bool {
        // Verify both tabs exist
        guard let sourceTab = tabs[sourceTabId],
              tabs[destinationTabId] != nil,
              !sourceTab.panes.isEmpty else {
            return false
        }
        
        // Don't allow moving to the same tab
        if sourceTabId == destinationTabId {
            return false
        }
        
        // Copy the panes to a local array to avoid mutation issues
        let sourcePanes = sourceTab.panes.asArray
        
        // Track if at least one pane was moved successfully
        var atLeastOneSuccess = false
        
        // Move each pane one by one
        for (index, pane) in sourcePanes.enumerated() {
            let isLast = index == sourcePanes.count - 1
            
            let success = moveToSplitView(
                sourceTabId: sourceTabId,
                sourcePaneId: pane.id,
                destinationTabId: destinationTabId,
                activatePane: activateLast && isLast
            )
            
            if success {
                atLeastOneSuccess = true
            }
            
            // If the source tab no longer exists, break the loop
            if tabs[sourceTabId] == nil {
                break
            }
        }
        
        return atLeastOneSuccess
    }

    /// Splits a multi-pane tab into individual tabs, one per pane. The first
    /// pane stays in the original tab; the remaining panes are moved into new
    /// tabs inserted directly after the original.
    /// - Returns: The IDs of all tabs that contain the panes after splitting (the
    ///   original first, then the new ones in order).
    @discardableResult
    public mutating func separateSplitTabs(tabId: ID<Tab>) -> [ID<Tab>] {
        guard let tab = tabs[tabId], tab.panes.count > 1,
              let win = windowContaining(tabId: tabId) else { return [] }
        let winId = win.id
        let originalLocation = location(ofTabId: tabId, inWindowId: winId)

        let panesToMove = tab.panes.asArray.dropFirst().asArray

        modifyTab(id: tabId) { t in
            if let firstPane = t.panes.asArray.first {
                t.panes = .init(items: [firstPane])
            }
            t.focusedPaneIdx = 0
        }

        var resultIds: [ID<Tab>] = [tabId]
        var insertOffset = 1
        for pane in panesToMove {
            var newTab = Tab(id: .assign(), panes: [pane])
            // Without this the tab fails the validLiveWebContentIds check and
            // BrowserStore evicts the pane's WebContent ~0.5s later, killing
            // any owned overlay session (e.g. terminal PTY).
            newTab.lastActiveInWindow = winId
            let location: SidebarLocation
            switch originalLocation {
            case .ordinaryTabs(let idx):
                location = .ordinaryTabs(idx + insertOffset)
            case .project(let projId, let idx):
                location = .project(projId, idx + insertOffset)
            case .favorites, .attachedAgent, .folder, nil:
                location = .ordinaryTabs((windows[winId]?.tabs.count ?? 0))
            }
            insertTab(newTab, location: location, inWindow: winId)
            resultIds.append(newTab.id)
            insertOffset += 1
        }
        return resultIds
    }

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
    
    public mutating func newWindow() -> WindowState {
        let win = WindowState(id: .assign(), profile: defaultProfileForNewWindows.id, lastActive: Date())
        self.windows[win.id] = win
        return win
    }
    
    @discardableResult
    public mutating func openTab(url: URL, activate: Bool = true, windowID: ID<WindowState>? = nil) -> Tab {
        let win: WindowState = (windowID != nil ? windows[windowID!] : nil) ?? getOrCreateActiveWindow()
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
    
    public mutating func activate(tabId id: ID<Tab>?, in window: ID<WindowState>) {
        // Folders aren't selectable
        if let id, tabs[id]?.isFolder == true { return }
        if let id, DefaultsKeys.allWindowsShareTabs.boolValue(defaultValue: true) {
            adoptTabFromOtherWindowIfNeeded(tabId: id, into: window)
        }
        if let old = windows[window]?.currentTab {
            modifyTab(id: old) { tab in
                tab.lastAccessed = Date(timeIntervalSinceNow: -0.1) // to break ties when we set the NEW tab to be active NOW
            }
        }
        windows[window]?.currentTab = id
        if let id {
            clearAttentionMarkers(forTabId: id)
            markFolderTabOpen(id)
            // An agent tab hidden behind the omnibox is being brought forward:
            // restore it to the sidebar first so it has a visible home.
            detachAgentTab(tabID: id, inWindow: window)
            modifyTab(id: id) { tab in
                tab.lastAccessed = Date()
                // Activating a pip tab in a window brings it back to main
                // content — the same webview can't live in both places.
                tab.pipMode = nil
                tab.pipOpen = nil
            }
        }
    }
    
    // MARK: - Shared tabs across windows (DefaultsKeys.allWindowsShareTabs)

    /// Tab IDs a window's sidebar lists for a space when tabs are shared across
    /// windows: this window's own tabs first, then the same space's tabs from
    /// every other window (most recently active window first).
    func sharedSidebarTabIDs(windowID: ID<WindowState>, profileID: ID<Profile>) -> [ID<Tab>] {
        var result = windows[windowID]?.perProfileData[profileID]?.tabs ?? []
        var seen = Set(result)
        for other in windowsMostRecentFirst where other.id != windowID {
            for tabID in other.perProfileData[profileID]?.tabs ?? [] where !seen.contains(tabID) {
                seen.insert(tabID)
                result.append(tabID)
            }
        }
        return result
    }

    /// If `tabId` is an ordinary tab of some *other* window, pull it out of that
    /// window (reselecting a neighbor there if it was current) and append it to
    /// this window's tab list for the same space.
    mutating func adoptTabFromOtherWindowIfNeeded(tabId: ID<Tab>, into window: ID<WindowState>) {
        guard windows[window] != nil else { return }
        guard let (source, profileID) = ordinaryTabOwner(tabId: tabId), source.id != window else { return }

        if source.currentTab == tabId {
            let replacement = tabToSelectAfterClosing(tabId: tabId)
            windows[source.id]?.currentTab = replacement
        }
        windows[source.id]?.perProfileData[profileID]?.tabs.removeAll { $0 == tabId }

        if windows[window]!.perProfileData[profileID] == nil {
            windows[window]!.perProfileData[profileID] = .init(tabs: [])
        }
        windows[window]!.perProfileData[profileID]!.tabs.append(tabId)
        modifyTab(id: tabId) { $0.lastActiveInWindow = window }
    }

    /// The window and space whose ordinary (non-favorite, non-project) tab list holds `tabId`.
    private func ordinaryTabOwner(tabId: ID<Tab>) -> (WindowState, ID<Profile>)? {
        for window in windowsMostRecentFirst {
            for (profileID, data) in window.perProfileData where data.tabs.contains(tabId) {
                return (window, profileID)
            }
        }
        return nil
    }

    /// Where an agent-spawned tab goes: directly beneath the tab of the pane
    /// that spawned it (a terminal running `claude`, or an agent chat tab),
    /// when that tab is in `window`'s current tab list; otherwise beneath the
    /// window's current tab, like a user-opened tab.
    func spawnInsertionIndex(window: ID<WindowState>, spawningPaneID: ID<WebContent>?) -> SidebarLocation {
        if let spawningPaneID, let tabID = paneToTabMapping[spawningPaneID],
           location(ofTabId: tabID, inWindowId: window) != nil {
            return insertionIndex(window: window, spawningTabId: tabID)
        }
        return insertionIndex(window: window, spawningTabId: windows[window]?.currentTab)
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
            case .attachedAgent, .folder:
                return .ordinaryTabs(win.tabs.count)
            }
        }
        if let proj = win.focusedOnProject {
            let projTabCounts = projects[proj]?.tabs.count ?? 0
            return .project(proj, projTabCounts)
        }
        return .ordinaryTabs(win.tabs.count)
    }
    
    public mutating func closeWindow(id: ID<WindowState>) {
        if let tabs = windows[id]?.tabs {
            for tab in tabs {
                _removeTab_unsafe_doesntCloseWebContent(tabId: tab, removeFromParent: false)
            }
        }
        for tab in windows[id]?.attachedAgentTabs ?? [] {
            _removeTab_unsafe_doesntCloseWebContent(tabId: tab, removeFromParent: false)
        }
        windows.removeValue(forKey: id)
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
        if let idx = win.attachedAgentTabs.firstIndex(of: tabId) {
            return .attachedAgent(idx)
        }
        for folderTabID in win.tabs {
            if let idx = tabs[folderTabID]?.folder?.tabs.firstIndex(of: tabId) {
                return .folder(folderTabID, idx)
            }
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
        
        let isCurrentTab = self.windows[winId]?.currentTab == tabId
        
        // Store the URL before closing the tab
        if tab.panes.count == 1, let url = tab.panes.first?.info.url {
            windows[winId]?.lastClosedTabURL = url
        }
        
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
            // Folder members reset to their pinned state and leave the
            // folder's open list; they stay in the folder.
            if folderTab(containingTabId: tabId) != nil {
                resetFolderTab(tabId)
            } else {
                resetToBase()
            }
            if isCurrentTab { reselect() }
            return
        }
        
        if tab.panes.count > 1 {
            // Don't close tab, just pane
            _removePane_unsafe(id: id)
        } else {
            if isCurrentTab { reselect() }
            remove()
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
                // Nearest selectable neighbor, preferring the one above.
                let candidates = win.tabs.filter { $0 != id && tabs[$0]?.isFolder != true }
                let above = win.tabs[..<idx].last(where: { tabs[$0]?.isFolder != true })
                return above ?? win.tabs[(idx + 1)...].first(where: { tabs[$0]?.isFolder != true }) ?? candidates.first
            case .project(let projectId, let idx):
                let projectTabs = projects[projectId]?.tabs ?? []
                return idx == 0 ? projectTabs.get(idx + 1) : projectTabs.get(idx - 1)
            case .attachedAgent:
                return nil
            case .folder:
                break // fall through to the most recently used ordinary tab
            }
        }
        return win.tabs.filter({ $0 != id && tabs[$0]?.isFolder != true }).max { tab1, tab2 in
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
            if window.attachedAgentTabs.contains(id) {
                return window
            }
        }
        // Folder members live wherever their folder tab does.
        if let folderTab = folderTab(containingTabId: id) {
            return windowContaining(tabId: folderTab.id)
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
    /// Hidden agent tab attached to the window's omnibox (see BrowserState+AttachedAgents).
    case attachedAgent(Int)
    /// Member of a sidebar folder (the folder tab's id, index within it). See TabFolder.
    case folder(ID<Tab>, Int)
}

extension WindowState {
    /// Transient toasts jump ahead of sticky ones, so a toast waiting on the
    /// user doesn't hold up the rest of the queue.
    public var currentToast: Toast? {
        return toasts.first(where: { $0.sticky != true }) ?? toasts.first
    }
}

extension BrowserState {
    /// Checks if a tab is pinned (favorite) based on its sidebar location
    /// - Parameters:
    ///   - tabId: The ID of the tab to check
    /// - Returns: Boolean indicating if the tab is in the favorites location
    public func isPinned(tabId: ID<Tab>) -> Bool {
        if let window = windowContaining(tabId: tabId),
           let location = location(ofTabId: tabId, inWindowId: window.id) {
            switch location {
            case .favorites, .folder: return true
            case .ordinaryTabs, .project, .attachedAgent: return false
            }
        }
        return false
    }
    
    /// Returns the most recently used tab that isn't the currently active tab
    /// - Parameter windowID: The ID of the window to find tabs in
    /// - Returns: The ID of the most recently used tab, or nil if there are no other tabs
    public func findPreviouslyActiveTab(inWindow windowID: ID<WindowState>) -> ID<Tab>? {
        guard let window = windows[windowID],
              let currentTabID = window.currentTab else {
            return nil
        }
        
        // Get all tabs in the window
        let allWindowTabs = tabsInVisibleOrder(inWindow: windowID)
        
        // Filter out the current tab and sort by last accessed date
        return allWindowTabs
            .filter { $0 != currentTabID }
            .compactMap { tabID -> (ID<Tab>, Date)? in
                guard let tab = tabs[tabID] else { return nil }
                return (tabID, tab.lastAccessed)
            }
            .sorted { $0.1 > $1.1 } // Sort descending by access date
            .first?.0 // Get the ID of the most recently accessed tab
    }
    
    /// Returns all tabs in a window in their visible display order
    /// - Parameter windowID: The ID of the window to find tabs in
    /// - Returns: Array of tab IDs in display order
    public func tabsInVisibleOrder(inWindow windowID: ID<WindowState>) -> [ID<Tab>] {
        guard let window = windows[windowID] else {
            return []
        }
        
        var visibleTabs: [ID<Tab>] = []
        
        // First add favorite tabs (pinned and auto)
        let favoriteTabs = favorites(profileId: window.profile)
        visibleTabs.append(contentsOf: favoriteTabs)
        
        // Then add either project tabs or main tabs
        if let focusedProjectID = window.focusedOnProject, 
           let project = projects[focusedProjectID] {
            // Add project tabs if a project is focused
            visibleTabs.append(contentsOf: project.tabs)
        } else {
            // Otherwise add main tabs
            visibleTabs.append(contentsOf: window.tabs)
        }
        
        // Folders aren't selectable; their open members show as rows under them.
        return visibleTabs.flatMap { id -> [ID<Tab>] in
            if let folder = tabs[id]?.folder { return folder.openTabs }
            return [id]
        }
    }
    
    public func tabsInRecencyOrder(inWindow windowID: ID<WindowState>, max: Int) -> [ID<Tab>] {
        tabsInVisibleOrder(inWindow: windowID).sorted(by: {
            let date1 = self.tabs[$0]?.lastAccessed ?? .distantPast
            let date2 = self.tabs[$1]?.lastAccessed ?? .distantPast
            return date1 > date2
        }).prefix(max).asArray
    }
//    state.setSwipeGestureOffset(offet, forWindowID: windowID)
    
    public mutating func setSwipeGestureOffset(_ offset: Int?, forWindowID windowID: ID<WindowState>) {
        let oldVal = windows[windowID]?.swipeGestureOffset
        windows[windowID]?.swipeGestureOffset = offset
        if offset == nil, let oldOffset = oldVal {
            let newSelectedTabId = tabsInRecencyOrder(inWindow: windowID, max: oldOffset + 1).get(oldOffset)
            if let newSelectedTabId {
                activate(tabId: newSelectedTabId, in: windowID)
            }
        }
    }
    
    // We don't want to allow >1 new tab page in sidebar
    mutating func closeUnactivatedNewTabPages(in windowID: ID<WindowState>) {
        // dont close anything pinned
        guard let window = windows[windowID] else { return }
        
        var visibleTabs: [ID<Tab>] = []
        // Then add either project tabs or main tabs
        if let focusedProjectID = window.focusedOnProject,
           let project = projects[focusedProjectID] {
            // Add project tabs if a project is focused
            visibleTabs.append(contentsOf: project.tabs)
        } else {
            // Otherwise add main tabs
            visibleTabs.append(contentsOf: window.tabs)
        }
        
        let toClose = visibleTabs
            .filter({ $0 != window.currentTab })
            .filter { id in
                if let tab = self.tabs[id], let pane = tab.panes.first, tab.panes.count == 1 {
                    return pane.info.isEmptyPage
                }
                return false
            }
        
        if toClose.isEmpty { return }
        DispatchQueue.main.async {
            // do this outside modify()
            for id in toClose {
                closeTab(tabID: id)
            }
        }
    }
}
