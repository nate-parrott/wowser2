import Foundation

// BrowserJSHost is the abstraction the JSContext runtime calls into when an
// agent's JS executes a `browser.*.*` method. The live implementation
// (BrowserJSLiveHost) drives BrowserStore + WKWebViews; tests inject a mock.
//
// All methods are async and may run off the main thread; implementations are
// responsible for hopping to main when touching UI state.
//
// Identity:
//   - "tabId" in this surface = `ID<WebContent>.raw` (per-pane webview id).
//     A multi-pane split tab exposes one tabId per pane.
//   - "windowId" = `ID<WindowState>.raw`.
//   - "splitId" = `ID<Tab>.raw`. A split is just a `Tab` holding >1 pane, so
//     every tabId belongs to exactly one splitId (of size 1 when unsplit).
//   - "spaceId" = `ID<Profile>.raw`. Spaces are profiles. A window displays one
//     space at a time, and each space keeps its OWN tab list per window
//     (`WindowState.perProfileData`) — so "the tabs in a space" is only
//     meaningful relative to a window.
public protocol BrowserJSHost: AnyObject, Sendable {
    /// `spaceId` nil = the window's currently-displayed space (the only tabs the
    /// user can see). Pass a spaceId to enumerate a background space's tabs.
    func tabsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSTabInfo]
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String
    /// Open a ghost (agent) tab — like `tabsOpen` with `background=true`, but
    /// the pane is flagged so the sidebar dims it and surfaces "Agent tab" as
    /// a subtitle. The audio/microphone/camera are also muted. The flag is
    /// cleared as soon as the user activates the tab from the sidebar.
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String
    /// Lease a pane for active agent use for `minutes` (default 60): keeps it
    /// rendering offscreen and flags it in the sidebar. `minutes <= 0`
    /// releases it. Returns the lease expiry as unix seconds (0 if released).
    func tabsUse(id: String, minutes: Double?) async throws -> Double
    /// Open `url` as a NEW PANE inside an existing split, rather than as a new
    /// tab. The pane joins the tab containing `besideTabId` (default: the
    /// window's current tab). Returns the new pane's tabId — navigate that id
    /// later to retarget the pane in place instead of stacking more panes.
    func tabsOpenSplit(url: String, besideTabId: String?, activate: Bool, windowId: String?) async throws -> String
    func tabsClose(id: String) async throws
    /// Activates the tab containing this pane AND focuses the pane within its split.
    func tabsActivate(id: String) async throws
    func tabsMove(id: String, toIndex: Int) async throws
    func tabsGet(id: String) async throws -> BrowserJSTabInfo
    func tabsNavigate(id: String, url: String) async throws

    // MARK: - Splits

    /// Every split in the window (including single-pane tabs, which are splits of size 1).
    func splitsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSSplitInfo]
    /// The split containing `tabId` (a pane id).
    func splitsGet(tabId: String) async throws -> BrowserJSSplitInfo
    /// Tear a split apart into one tab per pane. Returns the pane ids, in order.
    func splitsSeparate(tabId: String) async throws -> [String]

    // MARK: - Spaces (profiles)

    /// `windowId` nil = the current window; `tabIds`/`isCurrent` are reported
    /// relative to it. `includeHidden` surfaces spaces omitted from the sidebar.
    func spacesList(windowId: String?, includeHidden: Bool) async throws -> [BrowserJSSpaceInfo]
    func spacesGetCurrent(windowId: String?) async throws -> BrowserJSSpaceInfo?
    /// Switch a window to display `spaceId`.
    func spacesActivate(spaceId: String, windowId: String?) async throws
    /// Toggle chat mode for a space.
    func spacesSetChatMode(spaceId: String, enabled: Bool) async throws

    // MARK: - Folders (sidebar tab folders, per space)

    /// Folders in `spaceId` (default: the current window's space).
    func foldersList(spaceId: String?, windowId: String?) async throws -> [BrowserJSFolderInfo]
    func foldersGet(folderId: String) async throws -> BrowserJSFolderInfo
    /// Create an empty folder in a space. Returns its id.
    func foldersCreate(name: String, spaceId: String?, windowId: String?) async throws -> String
    func foldersRename(folderId: String, name: String) async throws
    /// Delete a folder. Members move to the window's ordinary tab list unless `closeTabs`.
    func foldersDelete(folderId: String, closeTabs: Bool, windowId: String?) async throws
    /// Put a tab (pane id) into a folder, pinning its current URL. `open` also
    /// lists it under the folder row right away.
    func foldersAddTab(tabId: String, folderId: String, open: Bool) async throws
    /// Drop a tab from its folder; the tab is closed.
    func foldersRemoveTab(tabId: String) async throws

    func contentRead(id: String, as kind: String) async throws -> String
    func contentScreenshot(id: String) async throws -> BrowserJSImage

    func pageEval(id: String, js: String) async throws -> Any?
    func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any?

    // MARK: - Computer use

    /// Click in the page at content coordinates `(x, y)`. `button` is one of
    /// "left" | "right" | "middle". `clickCount` allows double/triple clicks.
    func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws
    /// Type a string of text into the page (sequential key events). Modifiers
    /// in `text` are taken literally.
    func pageType(id: String, text: String) async throws
    /// Press a single named key, optionally with modifiers. `key` is a name
    /// like "Enter", "Escape", "ArrowDown", "Tab", "Backspace", or a single
    /// character. `modifiers` may include any of: "shift" "control" "option"
    /// "command".
    func pageKey(id: String, key: String, modifiers: [String]) async throws
    /// Scroll the page by `(dx, dy)` content pixels.
    func pageScroll(id: String, dx: Double, dy: Double) async throws

    func windowsList() async throws -> [BrowserJSWindowInfo]
    func windowsGetCurrent() async throws -> BrowserJSWindowInfo?
    func windowsGetById(id: String) async throws -> BrowserJSWindowInfo?

    // MARK: - Network capture (Section 7)

    func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary]
    func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary]
    func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse
    func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse
    func netCaptureOrigin(origin: String, enabled: Bool) async throws

    // MARK: - Webapps

    /// Create (or overwrite) a tang:// webapp from a map of relative file paths
    /// to file contents, then open it in a new tab. `files` must include an
    /// `index.html` entry point. When `exposeBrowserJS` is true the app's pages
    /// receive `window.browser` (the full BrowserJS surface). Returns the tabId.
    func webappCreate(name: String, files: [String: String], exposeBrowserJS: Bool) async throws -> String

    // MARK: - Agents

    /// Create a new agent session; returns its agentId. Turns are started with
    /// `agentSend` and observed via `agentMessages`/`agentAwait`.
    func agentCreate(options: BrowserJSAgentCreateOptions) async throws -> String
    /// Start a turn (message + optional images). Returns immediately.
    func agentSend(id: String, text: String, images: [BrowserJSImage]) async throws
    /// Wait (up to timeoutMs) for the agent to go idle. Returns `done:false` on
    /// timeout so callers can await again.
    func agentAwait(id: String, timeoutMs: Int, since: Int?) async throws -> BrowserJSAgentAwaitResult
    /// Answer an app-implemented tool call the agent is blocked on.
    func agentRespondTool(callId: String, text: String, isError: Bool) async throws
    /// Transcript entries with index >= since.
    func agentMessages(id: String, since: Int) async throws -> [BrowserJSAgentMessage]
    func agentList() async throws -> [BrowserJSAgentInfo]
    func agentInterrupt(id: String) async throws
    func agentDispose(id: String) async throws

    // MARK: - Chat mode (see ChatModeHost.swift)

    /// `agentKey` identifies the calling agent (nil for the MCP runtime).
    /// Shows a page as a card in the caller's thread and/or in the main view.
    func chatPresent(agentKey: String?, tabId: String?, url: String?, show: String, note: String?) async throws -> String
    func agentsSpawn(agentKey: String?, task: String, name: String?, model: String?, effort: String?, fileSystemTools: Bool, workingDirectory: String?, show: String) async throws -> BrowserJSSpawnedAgentInfo
    func agentsSend(agentKey: String?, toKey: String, text: String) async throws
    func agentsList(agentKey: String?) async throws -> [BrowserJSPeerAgentInfo]
    func agentsTranscript(key: String, since: Int) async throws -> [BrowserJSAgentMessage]
    func terminalOpen(agentKey: String?, cwd: String?, command: String?, show: String) async throws -> String
    func terminalRead(id: String, since: String?, maxChars: Int?) async throws -> BrowserJSTerminalRead
    func terminalWrite(id: String, text: String) async throws
    /// Write a note (markdown or HTML) to tang://notes/ and optionally present it.
    func notesWrite(agentKey: String?, title: String, markdown: String?, html: String?, show: String) async throws -> BrowserJSNoteInfo
    /// Scheduled tasks: the tasks.json path, data directory, and parsed tasks.
    func tasksList() async throws -> BrowserJSTasksInfo

    // User-created toolbar buttons (BrowserState.toolbar). See BrowserState+Toolbar.swift.
    func toolbarListButtons() async throws -> [CustomToolbarButton]
    func toolbarGetButton(id: String) async throws -> CustomToolbarButton?
    func toolbarCreateButton(label: String, icon: String?, bjs: String?, instructions: String?) async throws -> CustomToolbarButton
    /// `clearBJS` sets `bjs` to nil (clicks spawn an agent). Other nil fields are left as-is.
    func toolbarUpdateButton(id: String, label: String?, icon: String?, bjs: String?, clearBJS: Bool, instructions: String?) async throws -> CustomToolbarButton
    func toolbarRemoveButton(id: String) async throws
    /// Click the button programmatically, as if from the toolbar of `tabId` (default: the calling tab).
    func toolbarClickButton(id: String, tabId: String?) async throws

    // Durable per-host CSS/JS injection (CleanModeStore).
    func injectGet(host: String) async throws -> BrowserJSInjection
    func injectSet(host: String, css: String?, js: String?) async throws -> BrowserJSInjection
    func injectClear(host: String) async throws

    // Memory store (see MemoryStore.swift). Scopes are data-store UUIDs.
    func memoryScopes() async throws -> [BrowserJSMemoryScope]
    func memorySchema() async throws -> String
    func memoryQuery(scope: String?, sql: String, params: [Any], limit: Int) async throws -> [[String: Any]]
    func memoryOverview(scope: String?) async throws -> BrowserJSMemoryOverview
    func memorySetOverview(scope: String?, text: String) async throws -> BrowserJSMemoryOverview
}

public struct BrowserJSInjection: Codable, Equatable, Sendable {
    public var host: String
    public var css: String?
    public var js: String?
}

public struct BrowserJSMemoryScope: Codable, Equatable, Sendable {
    public var id: String
    public var names: [String]
    public var enabled: Bool
    public var eventCount: Int?
}

public struct BrowserJSMemoryOverview: Codable, Equatable, Sendable {
    public var scope: String
    public var text: String
    public var updatedAt: String?
    public var status: String
    public var statusDetail: String?
}

public struct BrowserJSSpawnedAgentInfo: Codable, Equatable, Sendable {
    public var key: String
    public var tabId: String
    public var url: String
    public init(key: String, tabId: String, url: String) { self.key = key; self.tabId = tabId; self.url = url }
}

public struct BrowserJSNoteInfo: Codable, Equatable, Sendable {
    public var url: String
    public var tabId: String?
    public init(url: String, tabId: String?) { self.url = url; self.tabId = tabId }
}

public struct BrowserJSPeerAgentInfo: Codable, Equatable, Sendable {
    public var key: String
    public var name: String?
    public var status: String
    public var tabId: String?
    public var url: String?
    public var parentKey: String?
    public var isSelf: Bool
    public init(key: String, name: String? = nil, status: String, tabId: String? = nil, url: String? = nil, parentKey: String? = nil, isSelf: Bool = false) {
        self.key = key; self.name = name; self.status = status; self.tabId = tabId; self.url = url; self.parentKey = parentKey; self.isSelf = isSelf
    }
}

public struct BrowserJSTerminalRead: Codable, Equatable, Sendable {
    public var text: String
    public var token: String
    public var running: Bool
    public var command: String?
    public var cwd: String?
    public init(text: String, token: String, running: Bool, command: String? = nil, cwd: String? = nil) {
        self.text = text; self.token = token; self.running = running; self.command = command; self.cwd = cwd
    }
}

public extension BrowserJSHost {
    func webappCreate(name: String, files: [String: String], exposeBrowserJS: Bool) async throws -> String {
        throw BrowserJSError.notImplemented("webapp.create")
    }

    // Defaults so test doubles need only implement what they exercise.
    // BrowserJSLiveHost overrides every one of these.
    func tabsOpenSplit(url: String, besideTabId: String?, activate: Bool, windowId: String?) async throws -> String {
        throw BrowserJSError.notImplemented("tabs.openSplit")
    }
    func splitsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSSplitInfo] {
        throw BrowserJSError.notImplemented("splits.list")
    }
    func splitsGet(tabId: String) async throws -> BrowserJSSplitInfo {
        throw BrowserJSError.notImplemented("splits.get")
    }
    func splitsSeparate(tabId: String) async throws -> [String] {
        throw BrowserJSError.notImplemented("splits.separate")
    }
    func spacesList(windowId: String?, includeHidden: Bool) async throws -> [BrowserJSSpaceInfo] {
        throw BrowserJSError.notImplemented("spaces.list")
    }
    func spacesGetCurrent(windowId: String?) async throws -> BrowserJSSpaceInfo? {
        throw BrowserJSError.notImplemented("spaces.getCurrent")
    }
    func spacesActivate(spaceId: String, windowId: String?) async throws {
        throw BrowserJSError.notImplemented("spaces.activate")
    }
    func spacesSetChatMode(spaceId: String, enabled: Bool) async throws {
        throw BrowserJSError.notImplemented("spaces.setChatMode")
    }
    func foldersList(spaceId: String?, windowId: String?) async throws -> [BrowserJSFolderInfo] {
        throw BrowserJSError.notImplemented("folders.list")
    }
    func foldersGet(folderId: String) async throws -> BrowserJSFolderInfo {
        throw BrowserJSError.notImplemented("folders.get")
    }
    func foldersCreate(name: String, spaceId: String?, windowId: String?) async throws -> String {
        throw BrowserJSError.notImplemented("folders.create")
    }
    func foldersRename(folderId: String, name: String) async throws {
        throw BrowserJSError.notImplemented("folders.rename")
    }
    func foldersDelete(folderId: String, closeTabs: Bool, windowId: String?) async throws {
        throw BrowserJSError.notImplemented("folders.delete")
    }
    func foldersAddTab(tabId: String, folderId: String, open: Bool) async throws {
        throw BrowserJSError.notImplemented("folders.addTab")
    }
    func foldersRemoveTab(tabId: String) async throws {
        throw BrowserJSError.notImplemented("folders.removeTab")
    }
    func agentCreate(options: BrowserJSAgentCreateOptions) async throws -> String {
        throw BrowserJSError.notImplemented("agent.create")
    }
    func agentSend(id: String, text: String, images: [BrowserJSImage]) async throws {
        throw BrowserJSError.notImplemented("agent.send")
    }
    func agentAwait(id: String, timeoutMs: Int, since: Int?) async throws -> BrowserJSAgentAwaitResult {
        throw BrowserJSError.notImplemented("agent.await")
    }
    func agentRespondTool(callId: String, text: String, isError: Bool) async throws {
        throw BrowserJSError.notImplemented("agent.respondTool")
    }
    func agentMessages(id: String, since: Int) async throws -> [BrowserJSAgentMessage] {
        throw BrowserJSError.notImplemented("agent.messages")
    }
    func agentList() async throws -> [BrowserJSAgentInfo] {
        throw BrowserJSError.notImplemented("agent.list")
    }
    func agentInterrupt(id: String) async throws {
        throw BrowserJSError.notImplemented("agent.interrupt")
    }
    func agentDispose(id: String) async throws {
        throw BrowserJSError.notImplemented("agent.dispose")
    }
    func chatPresent(agentKey: String?, tabId: String?, url: String?, show: String, note: String?) async throws -> String {
        throw BrowserJSError.notImplemented("present")
    }
    func agentsSpawn(agentKey: String?, task: String, name: String?, model: String?, effort: String?, fileSystemTools: Bool, workingDirectory: String?, show: String) async throws -> BrowserJSSpawnedAgentInfo {
        throw BrowserJSError.notImplemented("agents.spawn")
    }
    func agentsSend(agentKey: String?, toKey: String, text: String) async throws {
        throw BrowserJSError.notImplemented("agents.send")
    }
    func agentsList(agentKey: String?) async throws -> [BrowserJSPeerAgentInfo] {
        throw BrowserJSError.notImplemented("agents.list")
    }
    func agentsTranscript(key: String, since: Int) async throws -> [BrowserJSAgentMessage] {
        throw BrowserJSError.notImplemented("agents.transcript")
    }
    func terminalOpen(agentKey: String?, cwd: String?, command: String?, show: String) async throws -> String {
        throw BrowserJSError.notImplemented("terminal.open")
    }
    func terminalRead(id: String, since: String?, maxChars: Int?) async throws -> BrowserJSTerminalRead {
        throw BrowserJSError.notImplemented("terminal.read")
    }
    func terminalWrite(id: String, text: String) async throws {
        throw BrowserJSError.notImplemented("terminal.write")
    }
    func notesWrite(agentKey: String?, title: String, markdown: String?, html: String?, show: String) async throws -> BrowserJSNoteInfo {
        throw BrowserJSError.notImplemented("notes.write")
    }
    func tasksList() async throws -> BrowserJSTasksInfo { throw BrowserJSError.notImplemented("tasks.list") }
    func toolbarListButtons() async throws -> [CustomToolbarButton] { throw BrowserJSError.notImplemented("toolbar.list") }
    func toolbarGetButton(id: String) async throws -> CustomToolbarButton? { throw BrowserJSError.notImplemented("toolbar.get") }
    func toolbarCreateButton(label: String, icon: String?, bjs: String?, instructions: String?) async throws -> CustomToolbarButton { throw BrowserJSError.notImplemented("toolbar.create") }
    func toolbarUpdateButton(id: String, label: String?, icon: String?, bjs: String?, clearBJS: Bool, instructions: String?) async throws -> CustomToolbarButton { throw BrowserJSError.notImplemented("toolbar.update") }
    func toolbarRemoveButton(id: String) async throws { throw BrowserJSError.notImplemented("toolbar.remove") }
    func toolbarClickButton(id: String, tabId: String?) async throws { throw BrowserJSError.notImplemented("toolbar.click") }
    func injectGet(host: String) async throws -> BrowserJSInjection { throw BrowserJSError.notImplemented("inject.get") }
    func injectSet(host: String, css: String?, js: String?) async throws -> BrowserJSInjection { throw BrowserJSError.notImplemented("inject.set") }
    func injectClear(host: String) async throws { throw BrowserJSError.notImplemented("inject.clear") }
    func memoryScopes() async throws -> [BrowserJSMemoryScope] { throw BrowserJSError.notImplemented("memory.scopes") }
    func memorySchema() async throws -> String { throw BrowserJSError.notImplemented("memory.schema") }
    func memoryQuery(scope: String?, sql: String, params: [Any], limit: Int) async throws -> [[String: Any]] { throw BrowserJSError.notImplemented("memory.query") }
    func memoryOverview(scope: String?) async throws -> BrowserJSMemoryOverview { throw BrowserJSError.notImplemented("memory.overview") }
    func memorySetOverview(scope: String?, text: String) async throws -> BrowserJSMemoryOverview { throw BrowserJSError.notImplemented("memory.setOverview") }
}

public struct NetLogFilter: Codable, Sendable {
    public var tabId: String?
    public var urlRegex: String?
    public var method: String?
    public var since: Double?
    public var limit: Int?

    public init(tabId: String? = nil, urlRegex: String? = nil, method: String? = nil, since: Double? = nil, limit: Int? = nil) {
        self.tabId = tabId; self.urlRegex = urlRegex; self.method = method; self.since = since; self.limit = limit
    }
}

public struct NetEntrySummary: Codable, Sendable {
    public var id: String
    public var ts: Double
    public var url: String
    public var method: String
    public var status: Int
    public var request: NetEntryHalf
    public var response: NetEntryHalf

    public init(id: String, ts: Double, url: String, method: String, status: Int, request: NetEntryHalf, response: NetEntryHalf) {
        self.id = id; self.ts = ts; self.url = url; self.method = method; self.status = status
        self.request = request; self.response = response
    }
}

public struct NetEntryHalf: Codable, Sendable {
    public var headers: [String: String]
    public var body: String?

    public init(headers: [String: String], body: String?) {
        self.headers = headers; self.body = body
    }
}

public struct NetFetchRequest: Codable, Sendable {
    public var url: String?
    public var method: String?
    public var headers: [String: String]?
    public var body: String?
    /// Either a tab id (we'll attach that tab's cookies for the URL's origin)
    /// or the literal `"domain"` (use the latest captured cookies for the
    /// URL's domain). Nil = no cookies attached.
    public var cookiesFrom: String?

    public init(url: String? = nil, method: String? = nil, headers: [String: String]? = nil, body: String? = nil, cookiesFrom: String? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.cookiesFrom = cookiesFrom
    }
}

public struct NetFetchResponse: Codable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String

    public init(status: Int, headers: [String: String], body: String) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public struct BrowserJSTabInfo: Codable, Equatable, Sendable {
    public var id: String
    public var windowId: String?
    public var url: String?
    public var title: String?
    public var index: Int?
    public var kind: String   // "web" | "terminal" | "webapp" (for now: web|terminal)
    public var isGhost: Bool
    /// Unix seconds until which an agent holds this pane "in use" (see `tabs.use`).
    public var agentActiveUntil: Double?
    /// The split (`ID<Tab>`) this pane belongs to. Unsplit tabs still have one.
    public var splitId: String?
    /// All pane ids in this pane's split, in display order (includes `id`).
    /// Count > 1 means the user sees this tab side-by-side with others.
    public var splitTabIds: [String]
    /// Whether this pane is the focused one within its split.
    public var isFocusedInSplit: Bool
    /// The space (`ID<Profile>`) whose tab list contains this pane's tab.
    public var spaceId: String?
    /// The sidebar folder this pane's tab belongs to, if any (see `folders`).
    public var folderId: String?

    public init(id: String, windowId: String? = nil, url: String? = nil, title: String? = nil, index: Int? = nil, kind: String = "web", isGhost: Bool = false, agentActiveUntil: Double? = nil, splitId: String? = nil, splitTabIds: [String] = [], isFocusedInSplit: Bool = true, spaceId: String? = nil, folderId: String? = nil) {
        self.id = id; self.windowId = windowId; self.url = url; self.title = title; self.index = index; self.kind = kind; self.isGhost = isGhost; self.agentActiveUntil = agentActiveUntil
        self.splitId = splitId; self.splitTabIds = splitTabIds; self.isFocusedInSplit = isFocusedInSplit; self.spaceId = spaceId; self.folderId = folderId
    }
}

/// A split = one `Tab` holding one or more panes. Single-pane tabs are splits of size 1.
public struct BrowserJSSplitInfo: Codable, Equatable, Sendable {
    public var id: String            // ID<Tab>
    public var windowId: String?
    public var spaceId: String?
    /// Index in the window's tab strip.
    public var index: Int?
    /// Pane ids, left-to-right. Each is a valid `tabId` elsewhere in this API.
    public var tabIds: [String]
    public var focusedTabId: String?
    public var title: String?

    public init(id: String, windowId: String? = nil, spaceId: String? = nil, index: Int? = nil, tabIds: [String], focusedTabId: String? = nil, title: String? = nil) {
        self.id = id; self.windowId = windowId; self.spaceId = spaceId; self.index = index
        self.tabIds = tabIds; self.focusedTabId = focusedTabId; self.title = title
    }
}

/// A space (a `Profile`). `tabIds`/`splitIds`/`isCurrent` are relative to the
/// window they were resolved against — a space holds a different tab list in
/// each window.
public struct BrowserJSSpaceInfo: Codable, Equatable, Sendable {
    public var id: String
    /// User-entered title, if any.
    public var title: String?
    /// AI-generated title, shown as a placeholder when `title` is empty.
    public var autoTitle: String?
    /// What the UI actually shows: `title ?? autoTitle ?? "Space N"`.
    public var displayName: String
    public var emoji: String?
    /// Creation order — the space's position in the sidebar carousel.
    public var index: Int
    public var hidden: Bool
    /// Chat mode: the sidebar is a coordinator thread (see `present`).
    public var chatMode: Bool
    /// True if `windowId` is currently displaying this space.
    public var isCurrent: Bool
    /// Every window currently displaying this space.
    public var windowIds: [String]
    /// Pane ids of this space's tabs, in the resolved window.
    public var tabIds: [String]
    /// Split (`ID<Tab>`) ids of this space's tabs, in the resolved window.
    public var splitIds: [String]

    public init(id: String, title: String? = nil, autoTitle: String? = nil, displayName: String, emoji: String? = nil, index: Int = 0, hidden: Bool = false, chatMode: Bool = false, isCurrent: Bool = false, windowIds: [String] = [], tabIds: [String] = [], splitIds: [String] = []) {
        self.id = id; self.title = title; self.autoTitle = autoTitle; self.displayName = displayName
        self.emoji = emoji; self.index = index; self.hidden = hidden; self.chatMode = chatMode; self.isCurrent = isCurrent
        self.windowIds = windowIds; self.tabIds = tabIds; self.splitIds = splitIds
    }
}

/// A sidebar folder: a pane-less, non-selectable tab that groups pinned tabs.
/// `id` is the folder tab's split id; `index` its position in the tab strip.
public struct BrowserJSFolderInfo: Codable, Equatable, Sendable {
    public var id: String
    public var spaceId: String?
    public var windowId: String?
    public var index: Int?
    public var name: String
    /// Pane ids of every member, in folder order.
    public var tabIds: [String]
    /// Pane ids of members currently open (listed under the folder row).
    public var openTabIds: [String]
    /// Split (`ID<Tab>`) ids of every member, in folder order.
    public var splitIds: [String]

    public init(id: String, spaceId: String?, windowId: String?, index: Int?, name: String, tabIds: [String] = [], openTabIds: [String] = [], splitIds: [String] = []) {
        self.id = id; self.spaceId = spaceId; self.windowId = windowId; self.index = index; self.name = name
        self.tabIds = tabIds; self.openTabIds = openTabIds; self.splitIds = splitIds
    }
}

/// An image captured by the browser (e.g. from `content.screenshot`). Round-trips
/// to JS as `{mime, data}` and is what `browser.viewImage(...)` accepts.
public struct BrowserJSImage: Codable, Equatable, Sendable {
    public var mime: String
    public var data: String  // base64-encoded bytes

    public init(mime: String, data: String) {
        self.mime = mime
        self.data = data
    }
}

public struct BrowserJSWindowInfo: Codable, Equatable, Sendable {
    public var id: String
    public var tabIds: [String]
    public var currentTabId: String?
    /// The space this window is currently displaying. `tabIds` are that space's tabs.
    public var spaceId: String?
    /// Split (`ID<Tab>`) ids in the window's tab strip, in order.
    public var splitIds: [String]

    public init(id: String, tabIds: [String], currentTabId: String?, spaceId: String? = nil, splitIds: [String] = []) {
        self.id = id; self.tabIds = tabIds; self.currentTabId = currentTabId
        self.spaceId = spaceId; self.splitIds = splitIds
    }
}

public enum BrowserJSError: LocalizedError, Equatable {
    case tabNotFound(String)
    case windowNotFound(String)
    case spaceNotFound(String)
    case folderNotFound(String)
    case invalidArgs(String)
    case timeout
    case notImplemented(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .tabNotFound(let id): return "tab not found: \(id)"
        case .windowNotFound(let id): return "window not found: \(id)"
        case .spaceNotFound(let id): return "space not found: \(id)"
        case .folderNotFound(let id): return "folder not found: \(id)"
        case .invalidArgs(let msg): return "invalid args: \(msg)"
        case .timeout: return "timeout"
        case .notImplemented(let what): return "not implemented in v1: \(what)"
        case .underlying(let msg): return msg
        }
    }
}

public extension BrowserJSHost {
    /// Hosts without a stage (tests, iOS) don't support leases.
    func tabsUse(id: String, minutes: Double?) async throws -> Double {
        throw BrowserJSError.notImplemented("tabs.use")
    }
}
