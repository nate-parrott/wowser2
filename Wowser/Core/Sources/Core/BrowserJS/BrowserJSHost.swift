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
public protocol BrowserJSHost: AnyObject, Sendable {
    func tabsList(windowId: String?) async throws -> [BrowserJSTabInfo]
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String
    /// Open a ghost (agent) tab — like `tabsOpen` with `background=true`, but
    /// the pane is flagged so the sidebar dims it and surfaces "Agent tab" as
    /// a subtitle. The audio/microphone/camera are also muted. The flag is
    /// cleared as soon as the user activates the tab from the sidebar.
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String
    func tabsClose(id: String) async throws
    func tabsActivate(id: String) async throws
    func tabsMove(id: String, toIndex: Int) async throws
    func tabsGet(id: String) async throws -> BrowserJSTabInfo
    func tabsNavigate(id: String, url: String) async throws

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

    public init(id: String, windowId: String? = nil, url: String? = nil, title: String? = nil, index: Int? = nil, kind: String = "web", isGhost: Bool = false) {
        self.id = id; self.windowId = windowId; self.url = url; self.title = title; self.index = index; self.kind = kind; self.isGhost = isGhost
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

    public init(id: String, tabIds: [String], currentTabId: String?) {
        self.id = id; self.tabIds = tabIds; self.currentTabId = currentTabId
    }
}

public enum BrowserJSError: LocalizedError, Equatable {
    case tabNotFound(String)
    case windowNotFound(String)
    case invalidArgs(String)
    case timeout
    case notImplemented(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .tabNotFound(let id): return "tab not found: \(id)"
        case .windowNotFound(let id): return "window not found: \(id)"
        case .invalidArgs(let msg): return "invalid args: \(msg)"
        case .timeout: return "timeout"
        case .notImplemented(let what): return "not implemented in v1: \(what)"
        case .underlying(let msg): return msg
        }
    }
}
