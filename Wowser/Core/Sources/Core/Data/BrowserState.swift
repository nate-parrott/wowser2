import Combine
import WebKit
import Foundation

public struct BrowserState: Equatable, Codable {
    public var windows = [ID<WindowState>: WindowState]()
    public fileprivate(set) var tabs = [ID<Tab>: Tab]()
    public var profiles = [ID<Profile>: Profile]() // We should never be allowed to have zero profiles
    public var projects = [ID<Project>: Project]()
    /// Chat mode (browser-wide): every space's sidebar shows its coordinator
    /// chat thread instead of the tab list, and tabs surface as cards inside
    /// that thread. Threads are kept per space in both modes (see
    /// ChatSpaceSession), so toggling is free. Optional so old persisted
    /// state decodes.
    public var chatMode: Bool?
    public var isChatMode: Bool { chatMode == true }
    /// Trailing toolbar buttons: order, hidden set, user-created buttons.
    /// See BrowserState+Toolbar.swift. Optional so old persisted state decodes.
    public var toolbar: ToolbarConfig?
    
    // Lookup table
    public fileprivate(set) var paneToTabMapping = [ID<WebContent>: Tab.ID]()
    
    static var defaultState: BrowserState {
        BrowserState(
            windows: [:],
            tabs: [:],
            profiles: [
                ID<Profile>.defaultProfile: Profile(id: .defaultProfile, dataStoreUUID: UUID())
            ])
    }
}

public extension ID where Element == Profile {
    static var defaultProfile = Core.ID<Profile>(raw: "p0")
}

public struct Tab: Equatable, Identifiable, Codable {
    public var id: ID<Tab>
    public var panes = IdentifiedArray<Pane>() {
        didSet {
            focusedPaneIdx = max(0, min(panes.count - 1, focusedPaneIdx))
        }
    }
    public var lastAccessed: Date
    public var lastActiveInWindow: Core.ID<WindowState>?
    public var aiTags: AITags?
    public var focusedPaneIdx = 0
    public var customTitle: String?
    public var customEmoji: String? // User-chosen emoji shown in place of the favicon
    /// Picture-in-picture mode: the tab doesn't open in the window's main
    /// content; instead it shows as a floating panel. Optional for
    /// decode-compat with previously persisted states — read via `isPip`.
    public var pipMode: Bool?
    /// Whether the floating pip panel is currently shown (only meaningful when
    /// `pipMode == true`). Toggled by clicking the tab in the sidebar.
    public var pipOpen: Bool?
    /// Bumped to ask the sidebar row to "pop" (call attention to the tab, e.g.
    /// a new download). Rows observe it and animate on change.
    public var animationCount: Int?
    /// Set on sidebar folders: a pane-less, non-selectable tab that groups
    /// other tabs. See `TabFolder` / `BrowserState+Folders.swift`.
    public var folder: TabFolder?

    public init(id: Core.ID<Tab>, panes: [Pane], lastAccessed: Date = Date(), aiTags: AITags? = nil) {
        self.id = id
        self.panes = .init(items: panes)
        self.lastAccessed = lastAccessed
        self.aiTags = aiTags
    }

    /// The pane the user is currently interacting with, within this tab's split.
    public var focusedPane: Pane? { panes[focusedPaneIdx] }

    /// True when this tab is showing more than one pane side-by-side.
    public var isSplit: Bool { panes.count > 1 }

    /// True when this tab is in picture-in-picture mode (see `pipMode`).
    public var isPip: Bool { pipMode == true }
}

public struct AITags: Equatable, Codable {
    public var historyKeyWhenFetched: String
    public var groupName: String?
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
    public var weight: Double?
    /// Agent-opened "ghost" pane: live but not selected, muted, dimmed in the
    /// sidebar with an "Agent tab" subtitle. Cleared when the user activates
    /// the tab directly so it becomes a normal pane.
    public var isGhost: Bool = false
    /// While set (and in the future), an agent is actively driving this pane:
    /// it's kept mounted and visible-to-WebKit in the offscreen agent stage
    /// even though the user isn't looking at it, and the sidebar says so.
    /// Bumped by `browser.tabs.use` and implicitly by page/content calls;
    /// cleared by the stage's expiry sweep. Default lease is one hour.
    public var agentActiveUntil: Date?
    /// When an agent last touched this pane (lease set or bumped). Survives
    /// the lease so the sidebar can say "Agent was using this tab" until the
    /// user opens it. See `BrowserState.clearAttentionMarkers`.
    public var agentLastUsedAt: Date?
    /// Set by the lease sweep when the lease is still live but the agent
    /// hasn't touched the pane for `BrowserState.agentUseRecentSeconds`:
    /// the sidebar then says "was using" instead of "is using". Cleared on
    /// the next touch. Stored (not derived) because getters can't read the
    /// clock and nothing else would re-render the row when time passes.
    public var agentUseStale: Bool?
    /// Which engine backs this pane. Stamped when the live WebContent is first
    /// created (nil until then, and for panes persisted before this existed).
    /// Lives on Pane rather than Info because `pane.info` gets wholesale-reset
    /// on navigation.
    public var engine: BrowserEngine?
    /// Set on file-browser panes that were opened to show a download. The
    /// pane's URL points at the destination file; this record carries the
    /// live status/progress so the tab and the overlay can show it.
    public var download: Download?
    /// True after the LRU unloader dropped this pane's live web content to
    /// save memory (chat-mode spaces only). The page reloads from `info.url`
    /// the next time it's shown; cleared when the WebContent is recreated.
    public var unloaded: Bool?
    /// True while the external-link classifier is deciding which space this
    /// pane belongs in; the sidebar shows a subtitle. See BrowserStore+ExternalLinkSpaces.
    public var pickingSpace: Bool?
}

public struct Toast: Equatable, Codable, Identifiable {
    public var id: UUID
    public var message: String
    public var icon: String // SF Symbol name
    public var createdAt: Date
    public var location: ToastLocation
    /// Buttons shown in the toast (e.g. "Forget" / "Never for this site" on
    /// the autofill "Saved password" toast). Optional for decode-compat.
    public var actions: [ToastAction]?
    /// Seconds before auto-dismiss; nil = the default (5s).
    public var dismissAfter: TimeInterval?
    
    public enum ToastLocation: String, Codable {
        case normal
        case nearSidebar
    }
    
    public init(id: UUID = UUID(), message: String, icon: String, location: ToastLocation = .normal, createdAt: Date = Date(), actions: [ToastAction]? = nil, dismissAfter: TimeInterval? = nil) {
        self.id = id
        self.message = message
        self.icon = icon
        self.location = location
        self.createdAt = createdAt
        self.actions = actions
        self.dismissAfter = dismissAfter
    }
}

/// A button on a toast. Toasts live in persisted state, so actions are data
/// (what to do), not closures; `ToastAction.Kind.perform()` runs them.
public struct ToastAction: Equatable, Codable, Identifiable {
    public var title: String
    public var kind: Kind
    public var id: String { title }

    public enum Kind: Equatable, Codable {
        /// Remove the autofill records a submission just created.
        case autofillForget(profile: Core.ID<Profile>, ids: [UUID])
        /// Forget them AND stop remembering logins for this domain.
        case autofillNeverRemember(profile: Core.ID<Profile>, domain: String, ids: [UUID])
    }

    public init(title: String, kind: Kind) {
        self.title = title
        self.kind = kind
    }
}

public struct WindowState: Equatable, Codable {
    public var id: ID<WindowState>
    public var profile: ID<Profile>

    // Per-profile data passthru
    public var tabs: [ID<Tab>] {
        get { perProfileData[profile]?.tabs ?? [] }
        set { ensurePerProfileDataForCurProfile(); perProfileData[profile]!.tabs = newValue }
    }
    public var currentTab: ID<Tab>? {
        get { perProfileData[profile]?.currentTab }
        set { ensurePerProfileDataForCurProfile(); perProfileData[profile]!.currentTab = newValue }
    }
    public var focusedOnProject: ID<Project>? {
        get { perProfileData[profile]?.focusedOnProject }
        set { ensurePerProfileDataForCurProfile(); perProfileData[profile]!.focusedOnProject = newValue }
    }
    public var lastClosedTabURL: URL? {
        get { perProfileData[profile]?.lastClosedTabURL }
        set { ensurePerProfileDataForCurProfile(); perProfileData[profile]!.lastClosedTabURL = newValue }
    }
    /// Agent tabs "attached" to this window's omnibox: hidden from the sidebar
    /// and surfaced as a working indicator in the address bar instead. See
    /// `BrowserState+AttachedAgents.swift`.
    public var attachedAgentTabs: [ID<Tab>] {
        get { perProfileData[profile]?.attachedAgentTabs ?? [] }
        set { ensurePerProfileDataForCurProfile(); perProfileData[profile]!.attachedAgentTabs = newValue.isEmpty ? nil : newValue }
    }

    public var lastActive: Date?
    /// Bumped each time the window becomes key. Drives pane refocus: surface
    /// snapshots include this date so `.onAppearOrChange` fires on window-key
    /// the same way it fires on tab-switch (when `isFocused` flips).
    public var lastBecameKeyAt: Date?
    public var searchOverlayActive = false {
        didSet {
            if oldValue != searchOverlayActive, searchOverlayActive {
                print("Active")
            }
        }
    }
    /// Pane currently displaying the find-in-page bar (if any). Drives
    /// `focusState` toward `.findInPage`. Cleared by closing the bar or
    /// switching focus targets — never set in two places at once.
    public var findInPageActiveInPaneId: ID<WebContent>?
    /// Profile whose editable space-title field currently holds focus (if any).
    /// Drives `focusState` toward `.spaceTitle`. Set/cleared only via
    /// `didFocus`/`didLoseFocus` — never in two places at once.
    public var editingSpaceTitleForProfile: ID<Profile>?
    /// Chat-mode space whose sidebar chat input currently holds focus (if any).
    /// Drives `focusState` toward `.chatSpaceInput`. Commands (Cmd+T / Cmd+L
    /// in a chat-mode space) set it directly; blur clears it via `didLoseFocus`.
    public var chatInputActiveForProfile: ID<Profile>?
    public var toasts = [Toast]()
    public var sidebarLocked = true
    public var swipeGestureOffset: Int?
    /// The sidebar carousel is scrolled to the "new profile" page (past the
    /// last space). `profile` still points at the last space, so views use this
    /// to stop showing that space's look. Transient; the carousel resets it.
    public var showingNewProfilePage: Bool?
    /// Active element-picker session (transient UI state). See BrowserState+SelectorPicker.swift.
    public var selectorPicker: SelectorPickerSession?
    public var perProfileData = [ID<Profile>: PerProfileData]()
    public var tabsOpened = 0
    
    public struct PerProfileData: Equatable, Codable {
        public var tabs: [ID<Tab>]
        public var currentTab: ID<Tab>?
        public var focusedOnProject: ID<Project>?
        public var lastClosedTabURL: URL?
        /// Optional for decode-compat with previously persisted states.
        public var attachedAgentTabs: [ID<Tab>]?
    }
    
    private mutating func ensurePerProfileDataForCurProfile() {
        if perProfileData[profile] == nil {
            perProfileData[profile] = .init(tabs: [])
        }
    }
}

public struct Profile: Equatable, Codable {
    public var id: ID<Profile>
    public var dataStoreUUID: UUID
    public var creationOrder = 0
    public var manualFavorites = [ID<Tab>]()
    public var autoFavorites = [ID<Tab>]()
    public var removedFavoriteDomains = Set<String>() // url.hostWithoutWWW
    public var emoji: String? // Identifier emoji for the profile
    public var title: String? // Custom (user-entered) title for the profile
    public var autoTitle: String? // AI-generated title set during tab auto-organize; shown as placeholder when `title` is empty
    public var theme: SpaceTheme? // Auto-generated gradient/tint scheme derived from the title
    public var imageInfo: SpaceImageInfo? // User-dropped background image + tint/scheme derived from it; overrides `theme` visuals
    public var themeGeneratedForTitle: String? // Dedupe key: the effective title `theme`/`emoji` were last generated from
    /// Hidden profiles keep their tabs but are omitted from the sidebar carousel
    /// and paging dots. Restorable from Settings. Optional so old persisted state decodes.
    public var hidden: Bool?
    /// Folder this space is attached to (see "Add Folder…" in the space menu).
    /// Attaching a folder pins VS Code / terminal / files tabs for it.
    public var folderPath: String?
    /// Hosts (without www) of the last 20 distinct pages visited in this space,
    /// most recent first. Context for sorting external links into spaces.
    public var recentDomains: [String]?

    public var isHidden: Bool { hidden == true }
    /// User title, else the AI-generated one, else "Space N" (same fallback
    /// as the sidebar's SpaceNameLabel placeholder).
    public var displayName: String {
        title?.nilIfEmpty ?? autoTitle?.nilIfEmpty ?? "Space \(creationOrder + 1)"
    }
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
    
    private var liveWebContents = [ID<WebContent>: WebContent]() {
        didSet {
            #if os(macOS)
            // Agent-driven background tabs are parked in the offscreen stage
            // window, which retains their views. Unmount anything that was just
            // dropped so the page actually tears down.
            // liveWebContents is only ever mutated on the main thread (see the
            // assertOnMainThread() calls on every mutation path).
            MainActor.assumeIsolated {
                for (id, wc) in oldValue where liveWebContents[id] == nil {
                    AgentStageWindow.shared.unmount(wc.view)
                }
            }
            #endif
        }
    }
    var subscriptions = Set<AnyCancellable>()
    
    public override func setup() {
        super.setup()
        uiPublisher.throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
//            .map(\.validLiveWebContentIds)
//            .removeDuplicates()
            .sink { [weak self] ids in
                self?.removeWebContentNotInValidIds()
            }.store(in: &subscriptions)

        // Mirror per-pane ghost flag onto WebContent.silenced so agent-opened
        // background tabs stay muted (and unsilence when promoted to a normal
        // foreground tab).
        uiPublisher
            .map { state -> [ID<WebContent>: Bool] in
                var out: [ID<WebContent>: Bool] = [:]
                for tab in state.tabs.values {
                    for pane in tab.panes.asArray { out[pane.id] = pane.isGhost }
                }
                return out
            }
            .removeDuplicates()
            .sink { [weak self] ghostByPane in
                guard let self else { return }
                for (paneID, isGhost) in ghostByPane {
                    if let wc = self.liveWebContents[paneID], wc.silenced != isGhost {
                        wc.silenced = isGhost
                    }
                }
            }.store(in: &subscriptions)

        setupAutoArchiving()
        setupCleanupAfterLaunch()
        setupChatModeUnloader()
        setupChatThreadMirroring()
        
        // setupSearchFieldDismissOnSwitch
        addChangeHook { prev, next in
            if prev.activeWindow?.id == next.activeWindow?.id,
               // are we switching tabs...
               prev.activeWindow?.currentTab != next.activeWindow?.currentTab,
               let winID = prev.activeWindow?.id,
               // are we changing from an empty to non-empty page?
               prev.currentWebContentInfo(windowID: winID)?.isEmptyPage ?? false,
               !(next.currentWebContentInfo(windowID: winID)?.isEmptyPage ?? false)
            {
                next.windows[winID]?.searchOverlayActive = false
            }
        }

        // A tab that becomes a window's main tab has been seen: drop its
        // badge, whichever code path switched it (activate, drag/drop, adopt).
        addChangeHook { prev, next in
            for window in next.windows.values {
                if let tabID = window.currentTab, prev.windows[window.id]?.currentTab != tabID {
                    next.clearAttentionMarkers(forTabId: tabID)
                }
            }
        }
    }
    
    public override func processModelAfterLoad(model: inout BrowserState) {
        model.processAfterLoad()
    }
    
    /// The already-live WebContent for this pane, if any. Unlike `getOrCreateWebContent`,
    /// this never instantiates a WKWebView and never stamps `lastActiveInWindow`
    /// (which would pin the pane against the cleaner). Use this for opportunistic work
    /// like thumbnailing, where an unloaded pane simply has nothing to capture.
    public func existingWebContent(forId id: ID<WebContent>) -> WebContent? {
        assertOnMainThread()
        return liveWebContents[id]
    }

    /// Drops the live WKWebView for a pane without touching state. The pane
    /// recreates its web content next time it's displayed — used when a tab
    /// moves to a profile with a different website data store, so the webview
    /// doesn't keep the old profile's cookies/logins.
    public func unloadWebContent(forId id: ID<WebContent>) {
        assertOnMainThread()
        liveWebContents.removeValue(forKey: id)
    }

    /// The live WebContent for `id`, if one exists. Never creates one.
    public func liveWebContent(forId id: ID<WebContent>) -> WebContent? {
        assertOnMainThread()
        return liveWebContents[id]
    }

    /// Every pane that currently has a live WebContent.
    public var liveWebContentIDs: [ID<WebContent>] {
        assertOnMainThread()
        return Array(liveWebContents.keys)
    }

    public func getOrCreateWebContent(forId id: ID<WebContent>, toBeActiveInWindow windowID: ID<WindowState>) -> WebContent? {
        assertOnMainThread()
        let model = self.model
        if let live = liveWebContents[id] {
            // Update last-active-in-window
            // TODO: Catch tabs active in multiple windows
            if let tabId = model.paneToTabMapping[id],
                let tab = model.tabs[tabId],
               tab.lastActiveInWindow != windowID {
                self.model.tabs[tabId]?.lastActiveInWindow = windowID
                print("Switching tab.lastActiveInWindow for \(id)")
            }
            
            return live
        }
        // Need to create new webcontent:
        guard let tabId = model.paneToTabMapping[id],
                let pane = model.tabs[tabId]?.panes[id],
//              let win = model.windowContaining(tabId: tabId),
              let win = model.windows[windowID],
              let profile = model.profiles[win.profile]
        else {
            return nil
        }
        print("CREATING WC FOR TAB \(tabId)")

        // Engine is decided once per pane (first WebContent creation) and then
        // sticks, so a Chromium tab stays Chromium across unload/reload even if
        // the default-engine setting changes.
        let engine = pane.engine ?? BrowserEngine.preferredForNewPane(url: pane.info.url)

        modify { state in
            // Must set this otherwise tab will be unloaded
            state.tabs[tabId]?.lastActiveInWindow = windowID
            state.tabs[tabId]?.panes[id]?.engine = engine
            state.tabs[tabId]?.panes[id]?.unloaded = nil
        }

        let wc: WebContent
        #if canImport(CefKit) && os(macOS)
        if engine == .chromium {
            wc = WebContentChromium(id: id, datastoreUUID: profile.dataStoreUUID)
        } else {
            wc = WebContentWebKit(id: id, datastoreUUID: profile.dataStoreUUID)
        }
        #else
        wc = WebContentWebKit(id: id, datastoreUUID: profile.dataStoreUUID)
        #endif
        if pane.isGhost {
            wc.silenced = true
        }
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
        liveWebContents.removeValue(forKey: id) // the cleaner (removeWebContentNotInIds) handles this for tabs that were removed, but not ones that were pinned (bc their tabs are still alive)
        if let wv = liveWebContents[id]?.wkWebview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak wv] in
                if let wv {
                    softAssert("Expected to deallocate webview: \(wv)")
                }
            }
        }
    }

    private func removeWebContentNotInValidIds() {
        removeWebContentNotInIds(model.validLiveWebContentIds)
    }
    private func removeWebContentNotInIds(_ ids: Set<ID<WebContent>>) {
        let toRemove = liveWebContents.keys.filter { !ids.contains($0) }
        for id in toRemove {
            if let wv = liveWebContents[id]?.wkWebview {
                print("Trying to close web content '\(wv.title ?? "[no title]")'")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak wv] in
                    if let wv {
                        softAssert("Expected to deallocate webview: \(wv)")
                    }
                }
            }
            liveWebContents.removeValue(forKey: id)
        }
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
    public func createTab(withURL url: URL?, in windowID: ID<WindowState>, activate: Bool = true, inCurrentSplit: Bool = false) -> ID<Tab> {
        var tabID: ID<Tab>?
        
        modify { state in
            if inCurrentSplit, let currentTabID = state.windows[windowID]?.currentTab {
                let paneID = Core.ID<WebContent>.assign()
                let info = WebContent.Info(url: url, title: nil)
                let pane = Pane(id: paneID, info: info)
                state.modifyTab(id: currentTabID) { tab in
                    tab.panes.append(pane)
                    if activate {
                        tab.focusedPaneIdx = tab.panes.count - 1
                    }
                }
                
                tabID = currentTabID
            } else {
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
        }
        
        return tabID!
    }
    
}

extension BrowserStore: WebContentDelegate {
    public func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command), let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            // open in new tab
            // dont activate), but create so it begins to load:
            let info: WebContent.Info = .init(url: url)
            let newTab = Tab(id: .assign(), panes: [.init(id: .assign(), info: info)])
            modify { state in
                if let oldTabId = state.paneToTabMapping[webContent.id], let win = state.windowContaining(tabId: oldTabId) {
                    // TODO: Cascade past siblings
                    let location = state.insertionIndex(window: win.id, spawningTabId: oldTabId)
                    state.insertTab(newTab, location: location, inWindow: win.id)
                } else {
                    fatalError()
                }
            }
            // Ensure tab created:
            if let curTabId = model.paneToTabMapping[webContent.id], let curTab = model.tabs[curTabId], let win = curTab.lastActiveInWindow {
                _ = self.getOrCreateWebContent(forId: newTab.panes[0]!.id, toBeActiveInWindow: win)
            }
            return .cancel
        } else if NSEvent.modifierFlags.contains(.option), let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            // open in split:
            modify { state in
                let info: WebContent.Info = .init(url: url)
                if let oldTabId = state.paneToTabMapping[webContent.id] {
                    state.modifyTab(id: oldTabId) { tab in
                        tab.panes.append(.init(id: .assign(), info: info))
                        tab.focusedPaneIdx = tab.panes.count - 1
                    }
                } else {
                    fatalError()
                }
            }
            return .cancel
        }
        #endif
        return .allow
    }
    
    public func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
        return .allow
    }
    
    public func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool) {
        var winID: ID<WindowState>?
        MemoryStore.shared.noteSpawn(parent: webContent, child: newWebContent)
        
        modify { state in
            // TODO: Store tab parent?
            let newTab = Tab(id: .assign(), panes: [.init(id: newWebContent.id, info: newWebContent.info)])
            
            if let oldTabId = state.paneToTabMapping[webContent.id], let win = state.windowContaining(tabId: oldTabId) {
                winID = win.id
                let location = state.insertionIndex(window: win.id, spawningTabId: oldTabId)
                state.insertTab(newTab, location: location, inWindow: win.id)
                
                // Check if sidebar is not locked (hidden) and show toast in that case
                if !win.sidebarLocked {
                    let toast = Toast(
                        message: "Switched to New Tab",
                        icon: "arrow.up.forward.square",
                        location: .nearSidebar
                    )
                    state.windows[win.id]?.toasts.append(toast)
                }
            } else {
                // Kinda unexpected...
                let win = state.getOrCreateActiveWindow()
                winID = win.id
                state.insertTab(newTab, location: .ordinaryTabs(0), inWindow: win.id)
            }
            
            
            if shouldActivate, let winId = winID {
                state.activate(tabId: newTab.id, in: winId)
            }
        }
        
        setupBindings(webContent: newWebContent)
    }
    
    public func webContentWantsToClose(_ webContent: WebContent) {
        self.close(webContentId: webContent.id, removeIfPinned: false)
    }
    
    public func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?) {
        modify { state in
            state.updatePaneInfo(forWebContentId: webContent.id) { $0 = info }
            if let url = info.url, url.historyKey != previous?.url?.historyKey {
                state.noteVisitedDomain(url: url, forWebContentId: webContent.id)
            }
        }
        MemoryStore.shared.noteInfoChange(webContent: webContent, info: info, previous: previous)
        
//        let isNativeURL = info.url.flatMap(NativePageKey.init(url:)) != nil
        if let url = info.url, url.historyKey != previous?.url?.historyKey,
            let profile = self.model.profile(forWebContentId: webContent.id) {
            Queue.historyQueue.run {
                let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(profile.dataStoreUUID)
                store.trackVisitDebounced(url: url, title: info.title)
            }
        } else if let url = info.url, (url != previous?.url || info.title != previous?.title),
                    let profile = self.model.profile(forWebContentId: webContent.id) {
            // Update info
            Queue.historyQueue.run {
                let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(profile.dataStoreUUID)
                store.updatePageInfo(url: url, title: info.title?.nilIfEmpty)
            }
        }
    }
    
    public func webContentDidBecomeFirstResponder(_ webContent: WebContent) {
        modify { state in
            state.didFocus(target: .webContent(webContent.id))
        }
    }
}

extension BrowserState {
    func pane(forId id: ID<WebContent>) -> Pane? {
        if let tabId = paneToTabMapping[id], let tab = tabs[tabId] {
            return tab.panes[id]
        }
        return nil
    }
    
    public func currentPane(forWindow id: ID<WindowState>) -> Pane? {
        if let tabId = windows[id]?.currentTab, let tab = tabs[tabId], let pane = tab.panes[tab.focusedPaneIdx] {
            return pane
        }
        return nil
    }
    
    mutating func modifyPaneAndTab(forWebContentId id: ID<WebContent>, block: (inout Pane, inout Tab) -> Void) {
        if let tabId = paneToTabMapping[id], var tab = tabs[tabId], var pane = tab.panes.first(where: { $0.id == id }) {
            block(&pane, &tab)
            tab.panes[pane.id] = pane
            tabs[tabId] = tab
        }
    }

    mutating func setPaneWeights(tabId: ID<Tab>, leftPaneIdx: Int, leftWeight: Double, rightWeight: Double) {
        guard var tab = tabs[tabId],
              let left = tab.panes[leftPaneIdx],
              let right = tab.panes[leftPaneIdx + 1] else { return }
        var newLeft = left
        newLeft.weight = leftWeight
        var newRight = right
        newRight.weight = rightWeight
        tab.panes[left.id] = newLeft
        tab.panes[right.id] = newRight
        tabs[tabId] = tab
    }
    
    /// Clear the ghost flag on every pane in a tab. Called when the user
    /// activates the tab directly, promoting an agent-opened ghost tab to a
    /// normal foreground tab.
    public mutating func unghostTab(id: ID<Tab>) {
        guard var tab = tabs[id] else { return }
        var anyChange = false
        for pane in tab.panes.asArray {
            if pane.isGhost {
                var updated = pane
                updated.isGhost = false
                tab.panes[updated.id] = updated
                anyChange = true
            }
        }
        if anyChange {
            tabs[id] = tab
        }
    }

    mutating func makePaneActive(webContentID: ID<WebContent>) {
        if let tabID = tabContaining(paneId: webContentID) {
            modifyTab(id: tabID) { tab in
                if let idx = tab.panes.asArray.firstIndex(where: { $0.id == webContentID }) {
                    tab.focusedPaneIdx = idx
                }
            }
        }
    }
    
    /// The folder attached to the space showing this pane, if any. Used as the
    /// launch cwd for agents created in that space.
    func spaceFolderPath(forWebContentId id: ID<WebContent>) -> String? {
        profile(forWebContentId: id)?.folderPath?.nilIfEmpty
    }

    /// The folder attached to the space a window is currently showing, if any.
    func spaceFolderPath(windowID: ID<WindowState>?) -> String? {
        guard let windowID, let win = windows[windowID] else { return nil }
        return profiles[win.profile]?.folderPath?.nilIfEmpty
    }

    func profile(forWebContentId id: ID<WebContent>) -> Profile? {
        if let tabId = paneToTabMapping[id], let win = windowContaining(tabId: tabId), let profile = profiles[win.profile] {
            return profile
        }
        return nil
    }
    
    func windowContaining(webContentId id: ID<WebContent>) -> WindowState? {
        if let tabId = paneToTabMapping[id] {
            return windowContaining(tabId: tabId)
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
    
    // Can skip removeFromParent if these tabs are children of a window
    mutating func _removeTab_unsafe_doesntCloseWebContent(tabId: ID<Tab>, removeFromParent: Bool = true) {
        // A folder takes its members with it.
        for member in tabs[tabId]?.folder?.tabs ?? [] {
            _removeTab_unsafe_doesntCloseWebContent(tabId: member, removeFromParent: false)
        }
        let hosts = tabs[tabId]?.panes.compactMap { $0.info.url?.hostWithoutWWW }.asSet ?? Set()
        if let win = windowContaining(tabId: tabId) {
            let winId = win.id
            let profileId = win.profile
            if removeFromParent, let loc = location(ofTabId: tabId, inWindowId: winId) {
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
                case .attachedAgent(let idx):
                    windows[winId]?.attachedAgentTabs.remove(at: idx)
                case .folder:
                    _detachFromFolder(tabId)
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
    
    /// Registers a tab in `tabs` (and its panes in the lookup table) without
    /// placing it anywhere in a sidebar. Callers must list it somewhere.
    mutating func _registerTab_unsafe(_ tab: Tab) {
        tabs[tab.id] = tab
        for pane in tab.panes {
            paneToTabMapping[pane.id] = tab.id
        }
    }

    mutating func insertTab(_ tab: Tab, location: SidebarLocation, inWindow window: ID<WindowState>) {
        if tabs[tab.id] == nil {
            // this is new; let's increment the counter
            windows[window]?.tabsOpened += 1
        }
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
        case .attachedAgent(let idx):
            windows[window]?.attachedAgentTabs.insert(tab.id, at: idx)
        case .folder(let folderTabID, let idx):
            modifyTab(id: tab.id) { t in
                for i in t.panes.asArray.indices {
                    let info = t.panes[i]?.info
                    t.panes[i]?.baseInfo = info
                }
            }
            modifyFolder(id: folderTabID) { $0.tabs.insert(tab.id, at: min(idx, $0.tabs.count)) }
        }
    }
    
    mutating func insertTab(_ tab: Tab, intoProfileFavoritesAtIndex idx: Int, profile: ID<Profile>) {
        var tab = tab
        for i in tab.panes.asArray.indices {
            let info = tab.panes[i]?.info
            tab.panes[i]?.baseInfo = info
        }
        tabs[tab.id] = tab
        for pane in tab.panes {
            paneToTabMapping[pane.id] = tab.id
        }
        profiles[profile]!.manualFavorites.insert(tab.id, at: idx)
    }
    
    var validLiveWebContentIds: Set<ID<WebContent>> {
        return tabs.values.flatMap { tab -> [ID<WebContent>] in
            // Pip tabs live in a floating panel, not a window; keep them alive
            // regardless of lastActiveInWindow.
            if tab.isPip {
                return tab.panes.map(\.id)
            }
            // Was this tab last active in a living window?
            if let winId = tab.lastActiveInWindow, self.windows[winId] != nil {
                return tab.panes.map(\.id)
            }
            return []
        }.asSet
    }
    
    func currentWebContentInfo(windowID: ID<WindowState>) -> WebContent.Info? {
        if let curTabID = windows[windowID]?.currentTab, let curTab = tabs[curTabID], let pane = curTab.panes.elements.get(curTab.focusedPaneIdx) {
            return pane.info
        }
        return nil
    }
}

private extension BrowserState {
    mutating func processAfterLoad() {
        if DefaultsKeys.preserveWindowsAcrossRestarts.boolValue() {
            for windowID in windows.keys {
                windows[windowID]?.processAfterLoad()
            }
        } else {
            windows = [:]
        }
        resetTerminalRunStateAfterLoad()
    }

    /// No process can be running in a terminal tab right after launch, so
    /// drop each terminal pane's foreground command and turn a Claude Code
    /// spinner glyph in its title back into the idle glyph. The title text
    /// itself is kept so the sidebar still says what the tab was doing.
    mutating func resetTerminalRunStateAfterLoad() {
        for tab in tabs.values {
            for pane in tab.panes.asArray {
                guard let url = pane.info.url, NativePageKey(url: url)?.isTerminal == true else { continue }
                var info = pane.info
                info.terminalForegroundCommand = nil
                if let title = info.title,
                   let first = title.first,
                   WebContent.Info.claudeCodeRunningGlyphs.contains(first) {
                    info.title = String(WebContent.Info.claudeCodeIdleGlyph) + title.dropFirst()
                }
                if info != pane.info {
                    tabs[tab.id]?.panes[pane.id]?.info = info
                }
            }
        }
    }
}

private extension WindowState {
    mutating func processAfterLoad() {
        searchOverlayActive = false
        swipeGestureOffset = nil
        findInPageActiveInPaneId = nil
        chatInputActiveForProfile = nil
    }
}

// MARK: - Agent "in use" lease

public extension BrowserState {
    /// Default lease for `tabs.use` and implicit agent activity.
    static let agentUseLeaseSeconds: TimeInterval = 60 * 60
    /// How long after the last agent touch a live lease still counts as
    /// "Agent is using this tab" rather than "was using".
    static let agentUseRecentSeconds: TimeInterval = 2 * 60
    /// `touchAgentUse` only rewrites `agentLastUsedAt` when it's older than
    /// this, so chatty page/content calls don't churn state.
    static let agentUseTouchSlack: TimeInterval = 30

    /// Mark `paneID` as actively used by an agent until `until`. Pass nil to
    /// release it. Returns false if the pane doesn't exist.
    @discardableResult
    mutating func setAgentUse(paneID: ID<WebContent>, until: Date?, now: Date = Date()) -> Bool {
        guard let tabID = paneToTabMapping[paneID], tabs[tabID]?.panes[paneID] != nil else { return false }
        let visible = tabIsVisible(tabID)
        modifyTab(id: tabID) { tab in
            if var pane = tab.panes[paneID] {
                pane.agentActiveUntil = until
                if until != nil {
                    pane.agentLastUsedAt = now
                    pane.agentUseStale = nil
                } else if visible {
                    // Released while the user is looking at it: nothing to
                    // call attention to later.
                    pane.agentLastUsedAt = nil
                    pane.agentUseStale = nil
                }
                tab.panes[pane.id] = pane
            }
        }
        return true
    }

    /// Extend the lease to `now + lease` unless it already runs past
    /// `now + lease - slack`, so chatty callers don't rewrite state on every
    /// call. Returns true if state changed.
    @discardableResult
    mutating func touchAgentUse(paneID: ID<WebContent>, now: Date = Date(), lease: TimeInterval = BrowserState.agentUseLeaseSeconds, slack: TimeInterval = 10 * 60) -> Bool {
        guard let tabID = paneToTabMapping[paneID], let pane = tabs[tabID]?.panes[paneID] else { return false }
        if let until = pane.agentActiveUntil, until > now.addingTimeInterval(lease - slack) {
            // Lease is fresh; still record the touch (coarsely) so "is using"
            // stays accurate.
            let lastUsed = pane.agentLastUsedAt ?? .distantPast
            guard pane.agentUseStale == true || now.timeIntervalSince(lastUsed) > BrowserState.agentUseTouchSlack else { return false }
            modifyTab(id: tabID) { tab in
                tab.panes[paneID]?.agentLastUsedAt = now
                tab.panes[paneID]?.agentUseStale = nil
            }
            return true
        }
        return setAgentUse(paneID: paneID, until: now.addingTimeInterval(lease), now: now)
    }

    /// Clear every expired lease; returns the panes that were released.
    mutating func sweepExpiredAgentUse(now: Date = Date()) -> [ID<WebContent>] {
        var released: [ID<WebContent>] = []
        for tab in tabs.values {
            for pane in tab.panes.asArray where pane.agentActiveUntil.map({ $0 <= now }) == true {
                released.append(pane.id)
            }
        }
        for id in released { setAgentUse(paneID: id, until: nil, now: now) }
        // Live leases the agent hasn't touched in a while flip to "was using".
        for tab in tabs.values {
            for pane in tab.panes.asArray where pane.agentActiveUntil != nil && pane.agentUseStale != true {
                let lastUsed = pane.agentLastUsedAt ?? .distantPast
                if now.timeIntervalSince(lastUsed) > BrowserState.agentUseRecentSeconds {
                    modifyTab(id: tab.id) { $0.panes[pane.id]?.agentUseStale = true }
                }
            }
        }
        return released
    }
}
