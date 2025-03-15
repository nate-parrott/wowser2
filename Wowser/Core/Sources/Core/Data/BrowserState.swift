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

class BrowserStore: DataStore<BrowserState> {
    static let shared = BrowserStore(persistenceKey: "BrowserStore", defaultModel: .defaultState, queue: .main)
    
    private var liveWebContents = [ID<WebContent>: WebContent]()
    
    func getOrCreateWebContent(forId id: ID<WebContent>) -> WebContent? {
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
    
    func close(webContentId id: ID<WebContent>, removeIfPinned: Bool) {
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
}

extension BrowserStore: WebContentDelegate {
    func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        return .allow
    }
    
    func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
        return .allow
    }
    
    func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool) {
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
    
    func webContentWantsToClose(_ webContent: WebContent) {
        self.close(webContentId: webContent.id, removeIfPinned: false)
    }
    
    func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?) {
        modify { state in
            state.modifyPaneAndTab(forWebContentId: webContent.id) { pane, _ in
                pane.info = info
            }
        }
        
        // Visit tracking
        if let url = info.url, url.historyKey != previous?.url?.historyKey,
            let profile = self.model.profile(forWebContentId: webContent.id) {
            Queue.historyQueue.run {
                profile.id.historyStore.trackVisitDebounced(url: url, title: info.title)
            }
        } else if let url = info.url, (url != previous?.url || info.title != previous?.title),
                    let profile = self.model.profile(forWebContentId: webContent.id) {
            // Update info
            Queue.historyQueue.run {
                profile.id.historyStore.updatePageInfo(url: url, title: info.title?.nilIfEmpty)
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
