import Foundation
import WebKit
import Combine
import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - Engine

/// Which rendering engine backs a pane's live web content. Persisted per-pane
/// (see `Pane.engine`); chromium requires a build with CEF enabled
/// (see Core/Package.swift) and falls back to webkit otherwise.
public enum BrowserEngine: String, Codable {
    case webkit
    case chromium

    /// The engine a brand-new pane should get, honoring the Settings toggle.
    /// Native pages (tang://, terminal/file-browser overlays, generated pages)
    /// are built on WebKit machinery, so anything that isn't plain http(s)
    /// stays WebKit regardless of the toggle.
    static func preferredForNewPane(url: URL?) -> BrowserEngine {
        guard ChromiumSupport.isAvailable, DefaultsKeys.chromiumEngine.boolValue() else { return .webkit }
        if let url {
            guard url.scheme == "http" || url.scheme == "https" else { return .webkit }
            if NativePageKey(url: url) != nil { return .webkit }
        }
        return .chromium
    }
}

public protocol WebContentDelegate: AnyObject {
    func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy
    func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy
    func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool)
    func webContentWantsToClose(_ webContent: WebContent)
    func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?)
    func webContentDidBecomeFirstResponder(_ webContent: WebContent)
}

/// Engine-agnostic base class for a live tab's content. Concrete engines are
/// `WebContentWebKit` (WKWebView; the default everywhere) and, in CEF-enabled
/// macOS builds, `WebContentChromium`. Shared surface lives here so the rest of
/// the app can hold plain `WebContent` references; engine-specific features
/// (JS injection, snapshots, element picker, …) either go through the
/// overridable methods below or via `wkWebview`, which is nil for Chromium.
public class WebContent: NSObject, ObservableObject {
    weak var delegate: WebContentDelegate?

    let id: ID<WebContent>
    let datastoreUUID: UUID

    /// Storage for native overlays (terminal sessions, future webapp shells, etc.)
    /// that need to survive SwiftUI view re-mounts and tab switches. The
    /// reference is held for the lifetime of this WebContent — it gets evicted
    /// when the WebContent itself is dropped (via the same lifecycle that
    /// retires inactive web tabs in BrowserStore.removeWebContentNotInValidIds).
    public var overlayObject: AnyObject?

    deinit {
        print("Webcontent deinit")
    }

    // MARK: - API

    public struct Info: Equatable, Codable {
        public var url: URL?
        public var oldOnscreenURL: URL? // During nav, `url` may show a not-yet-committed url. If this field is set, we're in this state, and you can use this prop to get the existing committed url.
        public var title: String?
        public var canGoBack = false
        public var canGoForward = false
        public var estimatedProgress: Double = 0
        public var isLoading = false
        public var inferredDarkMode = false
        public var autoDarkModeApplied = false
        public var topColor: HSBA?
        public var underPageBackgroundColor: HSBA?
        public var favicon: URL?
        public var ogImage: URL?
        public var isSecure = false
        public var readerAvailable: Bool? // corresponds to fullContentExtractionStatus.readerContent; requires fullContentExtractionMode to bet set; no diff between nil and false
        public var recipeDetected: Bool? // Always being checked
        /// True when the page's viewport meta tag declares width=device-width,
        /// i.e. the page is mobile-responsive. Drives the pip panel's logical
        /// rendering width.
        public var mobileViewport: Bool?
        public var failedNavToURL: FailedNav?
        /// Native terminal tabs only: the command the PTY's foreground process
        /// group is running (e.g. "npm run dev"), or nil at the shell prompt.
        /// Drives the tab subtitle and the lit/dim terminal icon.
        public var terminalForegroundCommand: String?
        /// Native agent tabs only: true while the agent is mid-turn. Drives the
        /// tab's fruit icon expression and working subtitle.
        public var agentIsWorking: Bool?
        /// Native agent tabs only: granular status while working, e.g.
        /// "Thinking…" / "Driving the browser…" / "Writing…". Shown as the
        /// tab subtitle.
        public var agentStatusDetail: String?
        /// The editable element (input / textarea / contenteditable) that
        /// currently has focus in the page, if any — a heuristic, refreshed
        /// after clicks, keystrokes, scrolls and navigations (debounced).
        /// Drives the dictation target + its outline overlay.
        public var focusedEditable: FocusedEditable?

        public struct FocusedEditable: Equatable, Codable {
            /// Bounding rect in the webview's viewport coordinate space (CSS px).
            public var x: Double
            public var y: Double
            public var width: Double
            public var height: Double
            /// "input" | "textarea" | "contenteditable"
            public var kind: String
            public var multiline: Bool

            public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }

        public var committedURL: URL? {
            oldOnscreenURL ?? url
        }

        public struct FailedNav: Equatable, Codable {
            public var url: URL
            public var error: NavError
            public enum NavError: Equatable, Codable {
                case generic(String)
            }
        }
    }

    @Published public internal(set) var info = Info() {
        didSet {
            if info != oldValue {
                delegate?.webContent(self, infoDidChange: info, previous: oldValue)
            }
        }
    }

    public static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_8) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    public static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"

    /// The user agent this webview sends when `usesMobileUserAgent` is off.
    public static var defaultUserAgent: String {
        #if os(macOS)
        desktopUserAgent
        #else
        mobileUserAgent
        #endif
    }

    init(id: ID<WebContent>?, datastoreUUID: UUID) {
        self.id = id ?? .assign()
        self.datastoreUUID = datastoreUUID
        super.init()

        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        NotificationCenter.default.addObserver(self, selector: #selector(appDidForeground), name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif
    }

    // MARK: - Engine surface (overridden by concrete engines)

    /// Which engine backs this content.
    public var engine: BrowserEngine { .webkit }

    /// The view to mount into the pane hierarchy.
    public var view: UINSView { fatalError("WebContent subclass must override `view`") }

    /// The backing WKWebView when this content is WebKit-backed; nil for
    /// Chromium. Feature code that genuinely needs WebKit (snapshots, element
    /// picker, cookie stores, …) should unwrap this and degrade gracefully.
    public var wkWebview: WebContentWebView? { nil }

    public func load(url: URL) {}
    public func load(request: URLRequest) {}
    /// Loads `url`, and as soon as it commits (so it has a back/forward
    /// entry), loads `next`. Used to seed a back-stack entry (e.g. the search
    /// results page) when the omnibox jumps straight to a site. Engines that
    /// don't support this just load `next`.
    public func load(url: URL, thenLoad next: URL) { load(url: next) }
    public func load(html: String, baseURL: URL?) {}
    public func goBack() {}
    public func goForward() {}
    public func reload() {}
    public func focus() {}

    /// Increases the zoom level of the web content
    public func zoomIn() {}
    /// Decreases the zoom level of the web content
    public func zoomOut() {}
    /// Resets the zoom level to the default value
    public func resetZoom() {}
    /// Sets an absolute page zoom (used by pip panels to render the page at a
    /// fixed logical width and scale it to fill the panel).
    public func setPageZoom(_ zoom: CGFloat) {}

    public var silenced = false {
        didSet(old) {
            guard silenced != old else { return }
            silencedDidChange()
        }
    }
    func silencedDidChange() {}

    /// Dev mode's mobile emulation. Takes effect on the next navigation — callers
    /// that want it applied to the current page should `reload()`.
    public var usesMobileUserAgent = false {
        didSet {
            guard usesMobileUserAgent != oldValue else { return }
            userAgentDidChange()
        }
    }
    func userAgentDidChange() {}

    // MARK: - Configuration

    public var injectedCSS: String = "" {
        didSet(old) {
            if injectedCSS != old {
                updateInjectedCode()
            }
        }
    }

    public var injectedJS: String = "" {
        didSet(old) {
            if injectedJS != old {
                updateInjectedCode()
            }
        }
    }
    func updateInjectedCode() {}

    // MARK: - Full content extraction

    var fullContentExtractionMode: FullContentExtractionMode? {
        didSet {
            if fullContentExtractionMode != oldValue {
                fullContentExtractionStatus = .none
                fullContentExtractionModeDidChange()
            }
        }
    }
    func fullContentExtractionModeDidChange() {}

    @Published var fullContentExtractionStatus: FullContentExtractionStatus = .none {
        didSet {
            info.readerAvailable = fullContentExtractionStatus.readerContent == nil ? nil : true
        }
    }

    // MARK: - Populate

    public func populateWithInitialURL(_ url: URL) {
        populate { webContent in
            webContent.load(url: url)
        }
    }

    public func populateWithInitialRequest(_ request: URLRequest) {
        populate { webContent in
            webContent.load(request: request)
        }
    }

    public func populateWithInitialHTML(_ html: String, baseURL: URL?) {
        populate { webContent in
            webContent.load(html: html, baseURL: baseURL)
        }
    }

    private var populateBlock: ((WebContent) -> Void)?
    var waitingForRepopulationAfterProcessTerminate = false
    /// A webview's content process can be terminated while the app is in the background.
    /// `populate` allows you to handle this.
    /// Wrap your calls to load content into the webview within `populate`.
    /// The code will be called immediately, but _also_ after process termination.
    /// We do not expose `populate` directly to callers because there's a risk they'll capture `self` and cause a retain cycle.
    private func populate(_ block: @escaping (WebContent) -> Void) {
        waitingForRepopulationAfterProcessTerminate = false
        populateBlock = block
        block(self)
    }

    // MARK: - Lifecycle
    @objc private func appDidForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if self.waitingForRepopulationAfterProcessTerminate, let block = self.populateBlock {
                block(self)
            }
            self.waitingForRepopulationAfterProcessTerminate = false
        }
    }
}
