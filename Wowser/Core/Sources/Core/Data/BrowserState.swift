import WebKit
import Foundation

public struct BrowserState: Equatable, Codable {
    public var windows = [ID<WindowState>: WindowState]()
    public fileprivate(set) var tabs = [ID<Tab>: Tab]()
    public var profiles = [ID<Profile>: Profile]() // We should never be allowed to have zero profiles
    public var projects = [ID<Project>: Project]()
    
    // Lookup table
    public fileprivate(set) var paneToTabMapping = [ID<WebContent>: Tab.ID]()
    
    static var defaultState: BrowserState {
        BrowserState(
            windows: [:],
            tabs: [:],
            profiles: [
                ID<Profile>(raw: "p0"): Profile(id: .init(raw: "p0"), dataStoreUUID: UUID())
            ])
    }
}

public struct Tab: Equatable, Identifiable, Codable {
    public var id: ID<Tab>
    public var panes = IdentifiedArray<Pane>() {
        didSet {
            focusedPaneIdx = max(0, min(panes.count - 1, focusedPaneIdx))
        }
    }
    public var lastAccessed: Date
    public var aiLabel: String?
    public var focusedPaneIdx = 0
    
    public init(id: Core.ID<Tab>, panes: [Pane], lastAccessed: Date = Date(), aiLabel: String? = nil) {
        self.id = id
        self.panes = .init(items: panes)
        self.lastAccessed = lastAccessed
        self.aiLabel = aiLabel
    }
}

// MARK: - Tab Creation Helpers
extension Tab {
    /// Creates a new tab with a single pane containing the specified URL
    /// - Parameters:
    ///   - url: The URL to load in the tab
    ///   - title: Optional title for the tab
    /// - Returns: A new Tab instance with a single pane containing the URL
    public static func newTabWithURL(_ url: URL?, title: String? = nil) -> Tab {
        let paneID = Core.ID<WebContent>.assign()
        let info = WebContent.Info(url: url, title: title)
        let pane = Pane(id: paneID, info: info)
        
        return Tab(
            id: .assign(),
            panes: [pane],
            lastAccessed: Date()
        )
    }
    
    /// Creates a new empty tab
    /// - Returns: A new Tab instance with a single empty pane
    public static func newEmptyTab() -> Tab {
        let paneID = Core.ID<WebContent>.assign()
        let pane = Pane(id: paneID, info: WebContent.Info())
        
        return Tab(
            id: .assign(),
            panes: [pane],
            lastAccessed: Date()
        )
    }
}

public struct Pane: Equatable, Identifiable, Codable {
    public var id: ID<WebContent>
    public var info: WebContent.Info
    public var baseInfo: WebContent.Info?
}

public struct WindowState: Equatable, Codable {
    public var id: ID<WindowState>
    public var profile: ID<Profile>
    public var tabs = [ID<Tab>]()
    public var currentTab: ID<Tab>?
    public var lastActive: Date?
    public var focusedOnProject: ID<Project>?
    public var searchOverlayActive = false
}

public struct Profile: Equatable, Codable {
    public var id: ID<Profile>
    public var dataStoreUUID: UUID
    public var creationOrder = 0
    public var manualFavorites = [ID<Tab>]()
    public var autoFavorites = [ID<Tab>]()
    public var removedFavoriteDomains = Set<String>() // url.hostWithoutWWW
}

public struct Project: Equatable, Codable {
    public var id: ID<Project>
    public var manualName: String?
    public var aiName: String?
    public var lastUsed: Date?
    public var profile: ID<Profile>
    public var tabs = [ID<Tab>]()
}

public class BrowserStore: DataStore<BrowserState> {
    public static let shared = BrowserStore(persistenceKey: "BrowserStore", defaultModel: .defaultState, queue: .main)
    
    private var liveWebContents = [ID<WebContent>: WebContent]()
    
    public func getOrCreateWebContent(forId id: ID<WebContent>) -> WebContent? {
        if let live = liveWebContents[id] {
            return live
        }
        let model = self.model
        guard let tabId = model.paneToTabMapping[id],
                let pane = model.tabs[tabId]?.panes[id],
              let win = model.windowContaining(tabId: tabId),
              let profile = model.profiles[win.profile]
        else {
            return nil
        }
        let wc = WebContent(id: id, profileUUID: profile.dataStoreUUID)
        if let url = pane.info.url {
            wc.load(url: url)
        }
        if let tabId = model.paneToTabMapping[id], let pane = model.tabs[tabId]?.panes[id], let url = pane.info.url {
            wc.populateWithInitialURL(url)
        }
        setupBindings(webContent: wc)
        return wc
    }
    
    public func close(webContentId id: ID<WebContent>, removeIfPinned: Bool) {
        modify { state in
            state._close(webContentId: id, removeIfPinned: removeIfPinned)
        }
        liveWebContents.removeValue(forKey: id)
    }
    
    fileprivate func setupBindings(webContent: WebContent) {
        liveWebContents[webContent.id] = webContent
        webContent.delegate = self
    }
    
    func unloadOld() {
        // TODO: unload old webcontent
        // TODO: Call this
    }
    
    /// Creates and inserts a new tab with the specified URL into a window
    /// - Parameters:
    ///   - url: The URL to load in the tab
    ///   - windowID: The ID of the window to insert the tab into
    ///   - activate: Whether to activate the tab after insertion
    /// - Returns: The ID of the created tab
    @discardableResult
    public func createTab(withURL url: URL?, in windowID: ID<WindowState>, activate: Bool = true) -> ID<Tab> {
        var tabID: ID<Tab>?
        
        modify { state in
            // Create a new tab with the URL
            let tab = Tab.newTabWithURL(url)
            
            // Insert the tab into the window
            let insertLocation = state.insertionIndex(window: windowID, spawningTabId: state.windows[windowID]?.currentTab)
            state.insertTab(tab, location: insertLocation, inWindow: windowID)
            
            // Activate the tab if requested
            if activate {
                state.activate(tabId: tab.id, in: windowID)
            }
            
            tabID = tab.id
        }
        
        return tabID!
    }
    
    /// Closes all content in a window, including all tabs and panes.
    /// Also properly handles favorites that are open in the window.
    /// - Parameters:
    ///   - windowID: The ID of the window to close
    ///   - removeWindow: Whether to remove the window from the store after closing contents
    public func closeAllContentsInWindow(windowID: ID<WindowState>, removeWindow: Bool = true) {
        modify { state in
            guard let window = state.windows[windowID] else { return }
            
            // Get the profile for this window
            let profileID = window.profile
            
            // First, collect all tab IDs in this window - both regular tabs and favorites
            var tabsToClose = Set<ID<Tab>>(window.tabs)
            
            // Add favorites that may be open in this window
            if let profile = state.profiles[profileID] {
                let favorites = profile.manualFavorites + profile.autoFavorites
                for favoriteID in favorites {
                    if state.windowContaining(tabId: favoriteID)?.id == windowID {
                        tabsToClose.insert(favoriteID)
                    }
                }
            }
            
            // Close each tab and its contents
            for tabID in tabsToClose {
                // First get all the pane IDs before we modify the tab
                let paneIDs = state.tabs[tabID]?.panes.map { $0.id } ?? []
                
                // Close each pane in the tab
                for paneID in paneIDs {
                    state._close(webContentId: paneID, removeIfPinned: true)
                    self.liveWebContents.removeValue(forKey: paneID)
                }
            }
            
            // Finally, remove the window if requested
            if removeWindow {
                state.windows.removeValue(forKey: windowID)
            }
        }
    }
}

extension BrowserStore: WebContentDelegate {
    public func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        return .allow
    }
    
    public func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
        return .allow
    }
    
    public func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool) {
        modify { state in
            #if os(iOS)
            let openInSplit = false
            #else
            let openInSplit = NSEvent.modifierFlags.contains(.option)
            #endif
            // TODO: Store tab parent?
            let newTab = Tab(id: .assign(), panes: [.init(id: newWebContent.id, info: newWebContent.info)])
            if let oldTabId = state.paneToTabMapping[webContent.id], let win = state.windowContaining(tabId: oldTabId) {
                if openInSplit {
                    // Here, we actually forget about `newTab` and make a pane instead
                    state.modifyTab(id: oldTabId) { tab in
                        tab.panes.append(.init(id: newWebContent.id, info: newWebContent.info))
                        tab.focusedPaneIdx = tab.panes.count - 1
                    }
                } else {
                    let location = state.insertionIndex(window: win.id, spawningTabId: oldTabId)
                    state.insertTab(newTab, location: location, inWindow: win.id)
                }
//                state.windows[win.id]!.tabs.insert(newTab.id, at: idx)
            } else {
                // Kinda unexpected...
                let win = state.getOrCreateActiveWindow()
                state.insertTab(newTab, location: .ordinaryTabs(0), inWindow: win.id)
            }
        }
        setupBindings(webContent: newWebContent)
    }
    
    public func webContentWantsToClose(_ webContent: WebContent) {
        self.close(webContentId: webContent.id, removeIfPinned: false)
    }
    
    public func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?) {
        modify { state in
            state.modifyPaneAndTab(forWebContentId: webContent.id) { pane, _ in
                pane.info = info
            }
        }
        
        // Visit tracking
        if let url = info.url, url.historyKey != previous?.url?.historyKey,
            let profile = self.model.profile(forWebContentId: webContent.id) {
            Queue.historyQueue.run {
                profile.id.historyStore_historyQueueOnly.trackVisitDebounced(url: url, title: info.title)
            }
        } else if let url = info.url, (url != previous?.url || info.title != previous?.title),
                    let profile = self.model.profile(forWebContentId: webContent.id) {
            // Update info
            Queue.historyQueue.run {
                profile.id.historyStore_historyQueueOnly.updatePageInfo(url: url, title: info.title?.nilIfEmpty)
            }
        }
    }
}

extension BrowserState {
    mutating func modifyPaneAndTab(forWebContentId id: ID<WebContent>, block: (inout Pane, inout Tab) -> Void) {
        if let tabId = paneToTabMapping[id], var tab = tabs[tabId], var pane = tab.panes.first(where: { $0.id == id }) {
            block(&pane, &tab)
            tab.panes[pane.id] = pane
            tabs[tabId] = tab
        }
    }
    
    func profile(forWebContentId id: ID<WebContent>) -> Profile? {
        if let tabId = paneToTabMapping[id], let win = windowContaining(tabId: tabId), let profile = profiles[win.profile] {
            return profile
        }
        return nil
    }
    
    // does not close the tab if we reach zero panes
    mutating func _removePane_unsafe(id: ID<WebContent>) {
        if let tabId = paneToTabMapping[id] {
            tabs[tabId]?.panes.remove(id: id)
            paneToTabMapping.removeValue(forKey: id)
        }
    }
    
    mutating func _removeTab_unsafe_doesntCloseWebContent(tabId: ID<Tab>) {
        let hosts = tabs[tabId]?.panes.compactMap { $0.info.url?.hostWithoutWWW }.asSet ?? Set()
        if let win = windowContaining(tabId: tabId) {
            let winId = win.id
            let profileId = win.profile
            if let loc = location(ofTabId: tabId, inWindowId: winId) {
                switch loc {
                case .favorites:
                    profiles[profileId]?.autoFavorites.removeAll(where: { $0 == tabId })
                    profiles[profileId]?.manualFavorites.removeAll(where: { $0 == tabId })
                    for host in hosts {
                        // Do not let this become an auto fave in the future
                        profiles[profileId]?.removedFavoriteDomains.insert(host)
                    }
                case .ordinaryTabs(let idx):
                    windows[winId]?.tabs.remove(at: idx)
                case .project(let projId, let idx):
                    projects[projId]?.tabs.remove(at: idx)
                }
            }
        }
        for pane in tabs[tabId]?.panes.asArray ?? [Pane]() {
            paneToTabMapping.removeValue(forKey: pane.id)
        }
        tabs.removeValue(forKey: tabId)
    }
    
    mutating func modifyTab(id: ID<Tab>, block: (inout Tab) -> Void) {
        if var tab = tabs[id] {
            let oldPaneIds = tab.panes.map(\.id).asSet
            block(&tab)
            tabs[id] = tab
            let newPaneIds = tab.panes.map(\.id).asSet
            if oldPaneIds != newPaneIds {
                for id in oldPaneIds {
                    if !newPaneIds.contains(id) {
                        paneToTabMapping.removeValue(forKey: id)
                    }
                }
                for id in newPaneIds {
                    paneToTabMapping[id] = tab.id
                }
            }
        }
    }
    
    mutating func insertTab(_ tab: Tab, location: SidebarLocation, inWindow window: ID<WindowState>) {
        tabs[tab.id] = tab
        for pane in tab.panes {
            paneToTabMapping[pane.id] = tab.id
        }
        switch location {
        case .favorites:
            assertionFailure()
        case .ordinaryTabs(let idx):
            windows[window]?.tabs.insert(tab.id, at: idx)
        case .project(let id, let idx):
            projects[id]?.tabs.insert(tab.id, at: idx)
        }
    }
}
