#if canImport(CefKit) && os(macOS)
import AppKit
import CefKit
import Foundation

/// The Chromium (CEF) engine implementation, available only in CEF-enabled
/// macOS builds. Owns a `ChromiumBrowserHostView` which creates the underlying
/// `CefBrowser` lazily (CEF windowed browsers need a parent view inside a
/// window) and mirrors browser state into the shared `info` snapshot.
///
/// Current limitations vs WebKit tabs: no JS injection / adblock / auto dark
/// mode / element picker / BrowserJS agent APIs / find-in-page / snapshots.
/// Feature code reaches those through `wkWebview`, which is nil here, and
/// degrades gracefully.
public final class WebContentChromium: WebContent {
    let hostView: ChromiumBrowserHostView

    public override var engine: BrowserEngine { .chromium }
    public override var view: UINSView { hostView }

    public override init(id: ID<WebContent>?, datastoreUUID: UUID) {
        // Map Wowser's per-profile website data store onto a persistent CEF
        // profile so Chromium tabs get profile-scoped cookies/storage too.
        hostView = MainActor.assumeIsolated {
            ChromiumBrowserHostView(profileName: "wowser-\(datastoreUUID.uuidString)")
        }
        super.init(id: id, datastoreUUID: datastoreUUID)
        MainActor.assumeIsolated {
            hostView.owner = self
        }
    }

    // All engine entry points are called on the main thread in practice (UI
    // actions + BrowserStore's main-queue store); CefKit is @MainActor, so
    // hop explicitly.
    private func onMain(_ block: @MainActor (ChromiumBrowserHostView) -> Void) {
        MainActor.assumeIsolated {
            block(hostView)
        }
    }

    public override func load(url: URL) {
        onMain { $0.load(url: url) }
    }

    public override func load(request: URLRequest) {
        if let url = request.url {
            load(url: url)
        }
    }

    public override func load(html: String, baseURL: URL?) {
        // Chromium tabs can't load raw HTML strings yet; render via a data URL.
        let encoded = html.data(using: .utf8)?.base64EncodedString() ?? ""
        if let url = URL(string: "data:text/html;base64,\(encoded)") {
            load(url: url)
        }
    }

    public override func goBack() {
        onMain { $0.browser?.goBack() }
    }

    public override func goForward() {
        onMain { $0.browser?.goForward() }
    }

    public override func reload() {
        if let failedNav = info.failedNavToURL {
            info.failedNavToURL = nil
            load(url: failedNav.url)
        } else {
            onMain { $0.browser?.reload(ignoreCache: false) }
        }
    }

    public override func focus() {
        onMain { hostView in
            hostView.wowser_becomeFirstResponder(asTarget: .webContent(id))
            hostView.browser?.setFocus(true)
        }
    }

    private static let zoomIncrement: Double = 0.5 // CEF zoom is in Chromium zoom levels, not scale factors

    public override func zoomIn() {
        onMain { $0.browser?.zoomLevel += Self.zoomIncrement }
    }

    public override func zoomOut() {
        onMain { $0.browser?.zoomLevel -= Self.zoomIncrement }
    }

    public override func resetZoom() {
        onMain { $0.browser?.zoomLevel = 0 }
    }

    override func silencedDidChange() {
        onMain { $0.browser?.isAudioMuted = silenced }
    }
}

// MARK: - Host view

/// The NSView mounted into the pane hierarchy for a Chromium tab. Creates the
/// CEF browser the first time it lands in a window, keeps the CEF child view
/// sized to its bounds, acts as the browser's delegate, and closes the browser
/// when the owning WebContent goes away.
@MainActor
final class ChromiumBrowserHostView: NSView {
    weak var owner: WebContentChromium?
    private(set) var browser: CefBrowser?
    private let profileName: String
    private var pendingURL: URL?

    init(profileName: String) {
        self.profileName = profileName
        super.init(frame: .zero)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // NSViews deallocate on the main thread; close the browser with force
        // (the hosting UI is gone, so onbeforeunload prompts can't be shown).
        if let browser {
            MainActor.assumeIsolated {
                browser.delegate = nil
                browser.close(force: true)
            }
        }
    }

    func load(url: URL) {
        if let browser {
            browser.load(url)
        } else {
            pendingURL = url
            createBrowserIfPossible()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // CEF windowed browsers require a parent view in a window: this is the
        // earliest reliable creation point. If the browser already exists but
        // its native view got orphaned (SwiftUI re-mount), re-adopt it.
        if let browser {
            if let native = browser.nativeView, native.superview !== self {
                native.removeFromSuperview()
                addSubview(native)
                configure(browserView: native)
            }
            return
        }
        createBrowserIfPossible()
    }

    override func layout() {
        super.layout()
        if let native = browser?.nativeView, native.superview === self, native.frame != bounds {
            native.frame = bounds
        }
    }

    private func createBrowserIfPossible() {
        guard browser == nil, window != nil, ChromiumSupport.ensureRuntimeInitialized() else { return }
        var options = CefBrowserOptions()
        options.profile = .persistent(name: profileName)
        let url = pendingURL ?? URL(string: "about:blank")!
        pendingURL = nil
        let created = CefBrowser.createBrowser(
            parentView: self,
            bounds: bounds,
            url: url,
            options: options,
            delegate: self
        )
        browser = created
        if let native = created.nativeView {
            configure(browserView: native)
        }
        syncInfoFromBrowser()
    }

    private func configure(browserView: NSView) {
        browserView.frame = bounds
        browserView.autoresizingMask = [.width, .height]
    }

    private func syncInfoFromBrowser() {
        guard let owner, let browser else { return }
        var info = owner.info
        info.url = browser.url ?? info.url
        info.title = browser.title.nilIfEmpty ?? info.title
        info.isLoading = browser.isLoading
        info.canGoBack = browser.canGoBack
        info.canGoForward = browser.canGoForward
        info.isSecure = browser.url?.scheme == "https"
        owner.info = info
    }
}

// MARK: - CefBrowserDelegate

extension ChromiumBrowserHostView: CefBrowserDelegate {
    func browser(_ b: CefBrowser, didChangeTitle title: String) {
        owner?.info.title = title
    }

    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        guard let owner else { return }
        var info = owner.info
        info.url = url
        info.oldOnscreenURL = nil
        info.isSecure = url?.scheme == "https"
        owner.info = info
    }

    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let owner else { return }
        var info = owner.info
        info.isLoading = isLoading
        info.canGoBack = canGoBack
        info.canGoForward = canGoForward
        if !isLoading {
            info.estimatedProgress = 1
        }
        owner.info = info
    }

    func browser(_ b: CefBrowser, didChangeProgress progress: Double) {
        owner?.info.estimatedProgress = progress
    }

    func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
        owner?.info.favicon = urls.first
    }

    func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
        guard let owner, let url = URL(string: failedURL) else { return }
        // Mirror WebKit's failed-nav handling so the standard failure overlay shows.
        owner.info.failedNavToURL = .init(url: url, error: .generic("\(errorText) (\(code))"))
    }

    func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard let owner else { return .deny }
        guard let url = request.targetURL else {
            // about:blank popups (OAuth flows etc.): let CEF open a native popup.
            return .allowNativePopup
        }
        switch request.disposition {
        case .newForegroundTab, .newBackgroundTab, .newPopup, .newWindow, .unknown:
            let newWebContent = WebContentChromium(id: .assign(), datastoreUUID: owner.datastoreUUID)
            newWebContent.populateWithInitialURL(url)
            owner.delegate?.webContent(owner, didSpawnNewWebContent: newWebContent, shouldActivate: request.disposition.prefersForeground)
            return .handled
        default:
            return .openInCurrentBrowser
        }
    }

    func browserDidClose(_ b: CefBrowser) {
        browser = nil
        if let owner {
            owner.delegate?.webContentWantsToClose(owner)
        }
    }

    func browserDidGainFocus(_ b: CefBrowser) {
        if let owner {
            owner.delegate?.webContentDidBecomeFirstResponder(owner)
        }
    }

    func browser(_ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int) {
        owner?.waitingForRepopulationAfterProcessTerminate = true
    }
}
#endif
