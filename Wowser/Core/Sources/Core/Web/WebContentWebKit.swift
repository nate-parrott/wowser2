import Foundation
import WebKit
import Combine
import SwiftUI
import DominantColors
import Reeeed

#if os(macOS)
import AppKit
import Network
#endif

/// The WebKit-backed engine implementation — the default for every pane.
/// Owns a `WebContentWebView` (WKWebView subclass) and feeds its state into
/// the shared `info` snapshot via KVO + navigation delegate callbacks.
public class WebContentWebKit: WebContent, WKNavigationDelegate {
    public let webview: WebContentWebView
    private var observers = [NSKeyValueObservation]()
    var subscriptions = Set<AnyCancellable>()

    public override var engine: BrowserEngine { .webkit }
    public override var view: UINSView { webview }
    public override var wkWebview: WebContentWebView? { webview }

    // MARK: - Configuration
    @Published var blocklists = UserDefaults.standard.blocklistsActive

    #if os(iOS)
    var scrollEnabled: Bool {
        get { webview.scrollView.isScrollEnabled }
        set { webview.scrollView.isScrollEnabled = newValue }
    }
    #endif

    var autoDarkMode = DefaultsKeys.autoDarkMode.boolValue(defaultValue: false) {
        didSet {
            if autoDarkMode != oldValue {
                updateInjectedCode()
                updateTransparency()
            }
        }
    }

    override func userAgentDidChange() {
        webview.customUserAgent = usesMobileUserAgent ? Self.mobileUserAgent : Self.defaultUserAgent
    }

    public override func load(url: URL) {
        webview.load(.init(url: url))
    }

    public override func load(request: URLRequest) {
        webview.load(request)
    }

    /// (navigation, next): once `navigation` commits or fails, load `next`.
    private var loadAfterCommit: (WKNavigation, URL)?

    public override func load(url: URL, thenLoad next: URL) {
        loadAfterCommit = nil
        if let nav = webview.load(.init(url: url)) {
            loadAfterCommit = (nav, next)
        } else {
            webview.load(.init(url: next))
        }
    }

    /// Returns true if a queued follow-up load was kicked off for `navigation`.
    private func performLoadAfterCommitIfNeeded(for navigation: WKNavigation?) -> Bool {
        guard let (nav, next) = loadAfterCommit else { return false }
        if let navigation, nav !== navigation { return false }
        loadAfterCommit = nil
        webview.load(.init(url: next))
        return true
    }

    public override func load(html: String, baseURL: URL?) {
        webview.loadHTMLString(html, baseURL: baseURL)
    }

    public init(id: ID<WebContent>?, datastoreUUID: UUID, transparent: Bool = false, allowsInlinePlayback: Bool = false, autoplayAllowed: Bool = false, config: WKWebViewConfiguration? = nil) {
        let isFreshConfig = config == nil
        let config = config ?? WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        if #available(macOS 15.0, iOS 18.0, *), DefaultsKeys.hideSiriAIOnTextSelection.boolValue() {
            // Also hides macOS 27's floating Siri button that appears on text selection.
            config.writingToolsBehavior = .none
        }
        // Register the tang:// scheme + BrowserJS bridge on configs we own.
        // (Popup-inherited configs are skipped to avoid double-registration,
        // which would throw; tang apps are opened with fresh configs.)
        if isFreshConfig {
            TangBridge.install(on: config)
        }
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .throttle
            // https://stackoverflow.com/questions/78758812/wkwebview-oauth-popup-misses-window-opener-in-ios-17-5
            #if os(macOS)
            GlobalHacks.hacks!.fixPreferences(config.preferences)
            #endif
//            config.preferences.setValue(false, forKey: "processSwapOnCrossSiteNavigationEnabled")
        }
        if #available(macOS 14.0, *) {
            let dataStore = WKWebsiteDataStore(forIdentifier: datastoreUUID)
            #if os(macOS)
            // Route traffic through the local capturing proxy so the agent can
            // introspect requests via `browser.net.*`. HTTPS is only MITM'd for
            // origins on the capture allowlist; everything else blind-tunnels.
            dataStore.proxyConfigurations = WebContentWebKit.captureProxyConfigurations(port: LocalProxy.shared.syncBoundPort)
            #endif
            config.websiteDataStore = dataStore
        } else {
            // Fallback on earlier versions
            fatalError()
        }
        #if os(iOS)
        config.allowsInlineMediaPlayback = allowsInlinePlayback
        config.mediaTypesRequiringUserActionForPlayback = .all
        #endif
        if autoplayAllowed {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        webview = .init(frame: .zero, configuration: config)
        webview.allowsBackForwardNavigationGestures = true
        webview.allowsMagnification = true
//        if #available(iOS 16.4, macOS 13.3, *) {
//            webview.isInspectable = true
//        }
        #if os(macOS)
        webview.customUserAgent = Self.defaultUserAgent
        webview.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #else
        webview.customUserAgent = Self.mobileUserAgent
        #endif
        self.transparent = transparent
        super.init(id: id, datastoreUUID: datastoreUUID)
        webview.navigationDelegate = self
        webview.uiDelegate = self

        observers.append(webview.observe(\.url, options: [.new], changeHandler: { [weak self] _, _ in
            self?.needsMetadataRefresh()
        }))

        observers.append(webview.observe(\.title, options: [.new], changeHandler: { [weak self] _, _ in
            self?.needsMetadataRefresh()
        }))

        observers.append(webview.observe(\.canGoBack, options: [.new], changeHandler: { [weak self] _, val in
            self?.info.canGoBack = val.newValue ?? false
        }))

        observers.append(webview.observe(\.canGoForward, options: [.new], changeHandler: { [weak self] _, val in
            self?.info.canGoForward = val.newValue ?? false
        }))

        observers.append(webview.observe(\.estimatedProgress, options: [.new], changeHandler: { [weak self] _, val in
            self?.info.estimatedProgress = val.newValue ?? 0
        }))

        observers.append(webview.observe(\.isLoading, options: [.new], changeHandler: { [weak self] _, val in
            self?.info.isLoading = val.newValue ?? false
        }))

        observers.append(webview.observe(\.hasOnlySecureContent, options: [.new], changeHandler: { [weak self] _, val in
            self?.info.isSecure = val.newValue ?? false
        }))

        observers.append(webview.observe(\.underPageBackgroundColor, options: [.new], changeHandler: { [weak self] _, val in
            guard let self else { return }
            self.refreshAutoDarkMode()
            var updatedInfo = self.info
            updatedInfo.underPageBackgroundColor = val.newValue?.hsba
            self.info = updatedInfo
        }))


        #if os(iOS)
        webview.scrollView.backgroundColor = nil
        #endif
        updateTransparency()

        $blocklists.flatMap { blocklistsEnabled -> AnyPublisher<[WKContentRuleList], Never> in
            return AdblockManager.shared.$blocklists.map {
                $0?.filter({ blocklistsEnabled.contains($0.key) }).values.asArray ?? []
            }.eraseToAnyPublisher()
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] lists in
            self?.adblockRuleLists = lists
        }
        .store(in: &subscriptions)

        webview.onDarkModeChanged = { [weak self] darkMode in
            guard let self else { return }
            self.colorScheme = darkMode ? .dark : .light // self.webview.colorScheme
        }

        webview.onBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            self.delegate?.webContentDidBecomeFirstResponder(self)
            self.needsFocusedEditableRefresh()
        }

        #if os(macOS)
        webview.onMouseDown = { [weak self] event in
            guard let self, MemoryStore.shared.isActive else { return }
            MemoryStore.shared.noteMouseDown(webContent: self, webview: self.webview, event: event)
        }
        #endif
        MemoryFormBridge.install(on: webview.configuration, isFreshConfig: isFreshConfig, webContent: self)
        webview.onUserInteraction = { [weak self] in
            self?.needsFocusedEditableRefresh()
        }

        // Observe UserDefaults changes for settings
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }

                // Update adblock setting if changed in UserDefaults
                if self.blocklists != UserDefaults.standard.blocklistsActive {
                    self.blocklists = UserDefaults.standard.blocklistsActive
                }

                // Update autoDarkMode setting if changed in UserDefaults
                let autoDarkModeSetting = DefaultsKeys.autoDarkMode.boolValue(defaultValue: false)
                if self.autoDarkMode != autoDarkModeSetting {
                    self.autoDarkMode = autoDarkModeSetting
                }
            }
            .store(in: &subscriptions)
    }
    var colorScheme = ColorScheme.light {
        didSet {
            if colorScheme != oldValue, autoDarkMode {
                updateInjectedCode() // Update dark
            }
        }
    }

    override func silencedDidChange() {
        webview.setAllMediaPlaybackSuspended(silenced, completionHandler: nil)
        webview.setMicrophoneCaptureState(silenced ? .none : .active, completionHandler: nil)
        webview.setCameraCaptureState(silenced ? .none : .active, completionHandler: nil)
        // TODO: Disable going fullscreen
    }

    var transparent: Bool = false {
        didSet(old) {
            if transparent != old { updateTransparency() }
        }
    }

    public override func focus() {
        #if os(iOS)
        webview.becomeFirstResponder()
        #else
        webview.wowser_becomeFirstResponder(asTarget: .webContent(id))
        #endif
    }

    private func updateTransparency() {
        #if os(iOS)
        if transparent {
            webview.backgroundColor = nil
        } else if autoDarkMode {
            webview.backgroundColor = UIColor(named: "PureBackground", bundle: .module)!
        } else {
            webview.backgroundColor = UIColor.white
        }
        webview.isOpaque = !transparent
        #else
        // TODO
//        let secretSelector = NSSelectorFromString("setDrawsFish:".replacingOccurrences(of: "Fish", with: "Background"))
//        let secretProp = "drawsFish".replacingOccurrences(of: "Fish", with: "Background")
//        if webview.responds(to: secretSelector) {
//            webview.setValue(!transparent, forKey: secretProp)
//        }
        #endif
    }

    private var adblockRuleLists = [WKContentRuleList]() {
        didSet(old) {
            // TODO: is the userContentController shared between webviews?
            guard adblockRuleLists != old else { return }
            let added = adblockRuleLists.asSet.subtracting(old)
            let removed = old.asSet.subtracting(adblockRuleLists)
            for list in removed {
                webview.configuration.userContentController.remove(list)
            }
            for list in added {
                webview.configuration.userContentController.add(list)
            }
        }
    }

    public override func goBack() {
        webview.goBack()
    }

    public override func goForward() {
        webview.goForward()
    }

    public override func reload() {
        if let failedNav = info.failedNavToURL {
            info.failedNavToURL = nil
            load(url: failedNav.url)
        } else {
            webview.reload()
        }
    }

    // MARK: - Zoom
    private static let zoomIncrement: CGFloat = 0.1
    private static let defaultZoom: CGFloat = 1.0
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 3.0

    public override func zoomIn() {
        #if os(macOS)
        let currentMagnification = webview.pageZoom
        let newMagnification = min(currentMagnification + Self.zoomIncrement, Self.maxZoom)
        webview.pageZoom = newMagnification
        #endif
    }

    public override func zoomOut() {
        #if os(macOS)
        let currentMagnification = webview.pageZoom
        let newMagnification = max(currentMagnification - Self.zoomIncrement, Self.minZoom)
        webview.pageZoom = newMagnification
        #endif
    }

    public override func resetZoom() {
        #if os(macOS)
        webview.pageZoom = Self.defaultZoom
        #endif
    }

    public override func setPageZoom(_ zoom: CGFloat) {
        #if os(macOS)
        if webview.pageZoom != zoom {
            webview.pageZoom = zoom
        }
        #endif
    }

    // MARK: - WKNavigationDelegate
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if performLoadAfterCommitIfNeeded(for: navigation) { return }
        // A navigation that turned into a download (WebKitErrorDomain 102,
        // "Frame load interrupted") or was cancelled isn't a failure of the
        // page still onscreen — Safari/Chrome keep showing it. `info.url` is
        // KVO-synced with the webview, which has already reverted.
        let nsError = error as NSError
        if (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            info.oldOnscreenURL = nil
            return
        }
        if let failedURL = info.oldOnscreenURL {
            self.info.failedNavToURL = .init(url: failedURL, error: .generic("\(error)"))
        }
        self.info.oldOnscreenURL = webView.url

//        // Cold-start recovery: if a serve-web (vscode) URL nav fails because
//        // `code serve-web` isn't listening yet, redirect the webview to the
//        // `vscode-loading` sentinel page. The loading overlay polls until
//        // the server is up and then re-navigates to the real URL.
//        let nsError = error as NSError
//        if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
//           let failingURL = URL(string: urlString),
//           VSCodeConfig.isServeWebURL(failingURL) {
//            let folder = failingURL.queryParam(name: "folder")
//            let loadingURL = NativePageKey.vscodeLoading(folder: folder).url
//            webView.load(URLRequest(url: loadingURL))
//        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        info.oldOnscreenURL = nil
        info.failedNavToURL = nil
        needsMetadataRefresh()
        _ = performLoadAfterCommitIfNeeded(for: navigation)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        needsMetadataRefresh()
        MemoryStore.shared.notePageLoaded(webContent: self)
        // Trigger a final refresh a bit later, just in case stuff hasn't rendered yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.needsMetadataRefresh()
        }
    }

    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.webContentWantsToClose(self)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        func willAllowNav() {
            if navigationAction.targetFrame?.isMainFrame ?? false {
                self.info.oldOnscreenURL = webView.url
            }
        }

        if silenced {
            willAllowNav()
            decisionHandler(.allow, preferences)
            return
        }

        if navigationAction.shouldPerformDownload {
            if silenced {
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.download, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame ?? true,
            let delegate {
            let decision = delegate.webContent(self, decidePolicyFor: navigationAction)
            if decision == .allow {
                willAllowNav()
            }
            decisionHandler(decision, preferences)
            return
        }

        willAllowNav()
        decisionHandler(.allow, preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        if let delegate {
            let decision = delegate.webContent(self, decidePolicyForResponse: navigationResponse)
            decisionHandler(decision)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let windowID = BrowserStore.shared.model.windowContaining(webContentId: id)?.id else { return }
        DownloadManager.shared.webView(webView, navigationAction: navigationAction, didBecome: download, windowID: windowID)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let windowID = BrowserStore.shared.model.windowContaining(webContentId: id)?.id else { return }
        DownloadManager.shared.webView(webView, navigationResponse: navigationResponse, didBecome: download, windowID: windowID)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        waitingForRepopulationAfterProcessTerminate = true
    }

    // MARK: - Metadata
    private var _mdRefreshScheduled = false
    func needsMetadataRefresh() {
        if _mdRefreshScheduled { return }
        _mdRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.refreshMetadataNow()
        }
    }

    // MARK: - Focused editable element
    //
    // Pull-based: there's no cheap, reliable push signal for "a text field is
    // focused" across every page, so we re-check after user interaction and
    // navigation, coalesced to at most one JS eval per ~200ms.
    private var _focusedEditableRefreshScheduled = false
    func needsFocusedEditableRefresh() {
        if _focusedEditableRefreshScheduled { return }
        _focusedEditableRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self._focusedEditableRefreshScheduled = false
            self.refreshFocusedEditableNow()
        }
    }

    private static let focusedEditableJS = """
    (() => {
        let el = document.activeElement;
        // Descend into same-origin iframes when possible.
        for (let i = 0; i < 4 && el && el.tagName === 'IFRAME'; i++) {
            try { el = el.contentDocument && el.contentDocument.activeElement; } catch (_) { el = null; }
        }
        if (!el || el === document.body || el === document.documentElement) return null;
        const tag = el.tagName;
        let kind = null, multiline = false, sensitive = false;
        const ac = ((el.getAttribute && el.getAttribute('autocomplete')) || '').toLowerCase();
        const hint = ((el.name || '') + ' ' + (el.id || '') + ' ' + ac).toLowerCase();
        if (/cc-|one-time-code|password|passwd|cvv|cvc|card-?number|ssn/.test(hint)) sensitive = true;
        if (tag === 'TEXTAREA') { kind = 'textarea'; multiline = true; }
        else if (tag === 'INPUT') {
            const t = (el.getAttribute('type') || 'text').toLowerCase();
            const textual = ['text','search','email','url','tel','number','password',''];
            if (!textual.includes(t)) return null;
            if (el.readOnly || el.disabled) return null;
            if (t === 'password') sensitive = true;
            kind = 'input';
        } else if (el.isContentEditable) { kind = 'contenteditable'; multiline = true; }
        else return null;
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return null;
        return { x: r.left, y: r.top, width: r.width, height: r.height, kind, multiline, sensitive };
    })()
    """

    private func refreshFocusedEditableNow() {
        // Native overlay tabs have no meaningful DOM focus.
        if let url = webview.url, NativePageKey(url: url) != nil, !(NativePageKey(url: url)?.isVSCode ?? false) {
            if info.focusedEditable != nil { info.focusedEditable = nil }
            return
        }
        webview.evaluateJavaScript(Self.focusedEditableJS) { [weak self] result, _ in
            guard let self else { return }
            var value: Info.FocusedEditable?
            if let dict = result as? [String: Any],
               let x = dict["x"] as? Double, let y = dict["y"] as? Double,
               let w = dict["width"] as? Double, let h = dict["height"] as? Double,
               let kind = dict["kind"] as? String {
                value = Info.FocusedEditable(x: x, y: y, width: w, height: h, kind: kind, multiline: dict["multiline"] as? Bool ?? false, sensitive: (dict["sensitive"] as? Bool ?? false) ? true : nil)
            }
            if self.info.focusedEditable != value {
                self.info.focusedEditable = value
            }
        }
    }

    override func fullContentExtractionModeDidChange() {
        needsMetadataRefresh()
    }

    // do not call directly; call needsMetadataRefresh
    private func refreshMetadataNow() {
        self._mdRefreshScheduled = false

        var info = self.info
        // Native overlay tabs (terminal / file browser) own their own title;
        // the about:blank webview underneath always reports an empty title.
        // VSCode is a real webview, so its title comes from the page like any
        // other site.
        info.url = webview.url
        let suppressTitleFromWebview: Bool = {
            webview.url.flatMap(NativePageKey.init(url:))?.suppressTitleFromWebview ?? false
        }()
        if !suppressTitleFromWebview {
            info.title = webview.title
        }
        info.isSecure = webview.hasOnlySecureContent
        info.inferredDarkMode = webview.underPageBackgroundColor.hsba.brightness <= 0.4
        info.underPageBackgroundColor = webview.underPageBackgroundColor.hsba
        self.info = info
        needsFocusedEditableRefresh()

        Task {
            let docReadyWithURL: URL?
            do {
                let extracted = try await extractWebContentData()
                docReadyWithURL = extracted.isReady ? extracted.jsURL : nil
                // Favicons are loaded with URLSession (not WebKit), which can't
                // speak tang://, so resolve a tang app's icon to its file on disk.
                let favicon = extracted.favicon?.nilIfExtensionIs("svg").flatMap { $0.scheme == TangSchemeHandler.scheme ? $0.tangFileURL : $0 }
                DispatchQueue.main.async {
                    self.info.favicon = favicon
                    self.info.ogImage = extracted.ogImage
                    self.info.pageDescription = extracted.description?.nilIfEmpty
                    self.info.recipeDetected = extracted.isRecipe?.nilIfFalse
                    self.info.mobileViewport = extracted.mobileViewport
//                    print("RECIPE DETECTED: \(extracted.isRecipe?.nilIfFalse ?? false)")
                }
            } catch {
                docReadyWithURL = nil
                print("[🌐❌ Webview metadata extraction error] \(error)")
            }
            do {
                try await updateFullContentExtractionIfNecessary(docReadyWithURL: docReadyWithURL)
            } catch {
                print("[🌐❌ Full content extraction error] \(error)")
            }
        }

        if injectedCSS != "" || injectedJS != "" || autoDarkMode {
            updateInjectedCode()
        }

//         Capture the top portion of the page to determine dominant color
        Task {
            guard let hsba = await webview.extractTopDominantColor() else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Only update if different from current value
                if self.info.topColor != hsba {
                    var updatedInfo = self.info
                    updatedInfo.topColor = hsba
                    self.info = updatedInfo
                }
            }
        }
    }

    private func refreshAutoDarkMode() {
        guard autoDarkMode else { return }
        info.inferredDarkMode = webview.underPageBackgroundColor.hsba.brightness <= 0.4
        info.underPageBackgroundColor = webview.underPageBackgroundColor.hsba
        updateInjectedCode()
    }

    // MARK: - CSS Injection
    override func updateInjectedCode() {
        var injectedStyles = [injectedCSS]
//        print("[AD] Autodark: \(autoDarkMode), pageDark: \(info.inferredDarkMode), markMode: \(colorScheme == .dark)")
        let applyAutoDark = autoDarkMode && !info.inferredDarkMode && colorScheme == .dark
        if applyAutoDark != info.autoDarkModeApplied {
            info.autoDarkModeApplied = applyAutoDark
            self.needsMetadataRefresh() // If we are about to change auto-dark status, let's trigger a refresh
        }
        if applyAutoDark {
            injectedStyles.append("""
            html { filter: hue-rotate(180deg) invert(1) contrast(0.9) brightness(0.95); }
            img, video, object, iframe { filter: invert(1) hue-rotate(180deg); }
            """)
        }

        let escaped = injectedStyles.joined(separator: "\n").encodedAsJSONString
        let cssJS = """
// Find injected CSS if it already exists:
let css = document.getElementById('__webview_css');
if (css) {
    css.innerHTML = \(escaped);
} else {
    css = document.createElement('style');
    css.id = '__webview_css';
    css.innerHTML = \(escaped);
    document.head.appendChild(css);
}
"""
        webview.evaluateJavaScript((cssJS + "\n" + injectedJS).wrappedInSelfCallingJSFunction, completionHandler: nil)
    }
}

extension URL {
    func nilIfExtensionIs(_ ext: String) -> URL? {
        pathExtension == ext ? nil : self
    }

    /// For a `tang://<app>/<file>` URL, the file:// URL it's served from
    /// (on-disk app first, then bundled). Nil if the file doesn't exist.
    var tangFileURL: URL? {
        guard scheme == TangSchemeHandler.scheme, let host else { return nil }
        return TangAppStore.shared.resolveFile(forHost: host, path: path)
    }
}

extension UserDefaults {
    var blocklistsActive: Set<Blocklist> {
        var blocklists = Set<Blocklist>()
        if DefaultsKeys.adblock.boolValue(defaultValue: false) {
            blocklists.insert(.ads)
        }
        if DefaultsKeys.cookieBannerBlock.boolValue(defaultValue: false) {
            blocklists.insert(.cookies)
        }
        return blocklists
    }
}
