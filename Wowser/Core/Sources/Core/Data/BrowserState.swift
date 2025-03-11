import WebKit
import Foundation

public struct BrowserState: Equatable, Codable {
    public var windows = [ID<WindowState>: WindowState]()
    public var tabs = [ID<Tab>: Tab]()
    public var profiles = [ID<Profile>: Profile]() // We should never be allowed to have zero profiles
    
    static var defaultState: BrowserState {
        BrowserState(
            windows: [:],
            tabs: [:],
            profiles: [
                ID<Profile>(raw: "p0"): Profile(id: .init(raw: "p0"))
            ])
    }
}

public struct Tab: Equatable, Identifiable, Codable {
    public var id: ID<Tab>
    public var info: WebContent.Info
    public var lastAccessed: Date
    public var aiLabel: String?
    
    public init(id: ID<Tab>, info: WebContent.Info, lastAccessed: Date = Date(), aiLabel: String? = nil) {
        self.id = id
        self.info = info
        self.lastAccessed = lastAccessed
        self.aiLabel = aiLabel
    }
}

public struct WindowState: Equatable, Codable {
    public var id: ID<WindowState>
    public var profile: ID<Profile>
    public var tabs = [ID<Tab>]()
    public var currentTab: ID<Tab>?
    public var lastActive: Date?
}

public struct Profile: Equatable, Codable {
    public var id: ID<Profile>
    public var creationOrder = 0
    public var manualFavorites = [ID<Tab>]()
    public var autoFavorites = [ID<Tab>]()
    public var removedFavoriteDomains = Set<String>() // url.hostWithoutWWW
}

class BrowserStore: DataStore<BrowserState> {
    static let shared = BrowserStore(persistenceKey: "BrowserSrtore", defaultModel: .defaultState, queue: .main)
    
    private var liveWebContents = [ID<Tab>: WebContent]()
    
    func getOrCreateWebContent(forTabId tabId: ID<Tab>) -> WebContent {
        if let live = liveWebContents[tabId] {
            return live
        }
        let wc = WebContent(id: tabId)
        if let url = model.tabs[tabId]?.info.url {
            wc.populateWithInitialURL(url)
        }
        setupBindings(webContent: wc)
        return wc
    }
    
    func close(tabId id: ID<Tab>, removeIfPinned: Bool) {
        modify { state in
            state._close(tabId: id, removeIfPinned: removeIfPinned)
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
            // TODO: Store tab parent?
            state.tabs[newWebContent.id] = Tab(id: newWebContent.id, info: newWebContent.info)
            if let win = state.windowContaining(tabId: webContent.id) {
                let idx = state.insertionIndex(window: win.id, spawningTabId: webContent.id)
                state.windows[win.id]!.tabs.insert(newWebContent.id, at: idx)
            }
        }
        setupBindings(webContent: newWebContent)
    }
    
    func webContentWantsToClose(_ webContent: WebContent) {
        self.close(tabId: webContent.id, removeIfPinned: false)
    }
    
    func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info) {
        
    }
}
