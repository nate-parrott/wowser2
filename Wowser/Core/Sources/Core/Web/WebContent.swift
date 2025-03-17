import Foundation
import WebKit
import Combine
import SwiftUI

#if os(macOS)
import AppKit
#endif

class WebContentWebView: WKWebView {
    var onDarkModeChanged: ((Bool) -> Void)?

    #if os(iOS)
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection){
            onDarkModeChanged?(traitCollection.userInterfaceStyle == .dark)
        }
        
    }
    #endif
    
    #if os(macOS)
    override func layout() {
        super.layout()
        darkMode = NSAppearance.currentDrawing().name == .darkAqua
    }
    private var darkMode = false {
        didSet {
            if darkMode != oldValue {
                onDarkModeChanged?(darkMode)
            }
        }
    }
    #endif
    
}

public protocol WebContentDelegate: AnyObject {
    func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy
    func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy
    func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool)
    func webContentWantsToClose(_ webContent: WebContent)
    func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?)
}

public class WebContent: NSObject, WKNavigationDelegate, WKUIDelegate, ObservableObject {
    weak var delegate: WebContentDelegate?
    
    let id: ID<WebContent>
    let profileUUID: UUID
    let webview: WebContentWebView
    private var observers = [NSKeyValueObservation]()
    private var subscriptions = Set<AnyCancellable>()

    deinit {
        print("Webcontent deinit")
    }

    // MARK: - Configuration
    @Published var adblockEnabled = DefaultsKeys.adblock.boolValue(defaultValue: false)
    var injectedCSS: String = "" {
        didSet(old) {
            if injectedCSS != old {
                updateInjectedCode()
            }
        }
    }

    var injectedJS: String = "" {
        didSet(old) {
            if injectedJS != old {
                updateInjectedCode()
            }
        }
    }

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
    // MARK: - API
    public struct Info: Equatable, Codable {
        public var url: URL?
        public var title: String?
        public var canGoBack = false
        public var canGoForward = false
        public var estimatedProgress: Double = 0
        public var isLoading = false
        public var inferredDarkMode = false
    }

    @Published private(set) public var info = Info() {
        didSet {
            delegate?.webContent(self, infoDidChange: info, previous: oldValue)
        }
    }

    public func load(url: URL) {
        webview.load(.init(url: url))
    }

    public func load(request: URLRequest) {
        webview.load(request)
    }

    public func load(html: String, baseURL: URL?) {
        webview.loadHTMLString(html, baseURL: baseURL)
    }

    public init(id: ID<WebContent>?, profileUUID: UUID, transparent: Bool = false, allowsInlinePlayback: Bool = false, autoplayAllowed: Bool = false, config: WKWebViewConfiguration? = nil) {
        self.id = id ?? .assign()
        let config = config ?? WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileUUID)
        } else {
            // Fallback on earlier versions
            fatalError()
        }
        #if os(iOS)
        config.allowsInlineMediaPlayback = allowsInlinePlayback
        #endif
        if autoplayAllowed {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        webview = .init(frame: .zero, configuration: config)
        webview.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, macOS 13.3, *) {
            webview.isInspectable = true
        }
        #if os(macOS)
        webview.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        #else
        webview.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"
        #endif
        self.transparent = transparent
        self.profileUUID = profileUUID
        super.init()
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

        observers.append(webview.observe(\.underPageBackgroundColor, options: [.new], changeHandler: { [weak self] _, val in
            self?.refreshAutoDarkMode()
        }))


        #if os(iOS)
        webview.scrollView.backgroundColor = nil
        #endif
        updateTransparency()

        $adblockEnabled.flatMap { enabled -> AnyPublisher<WKContentRuleList?, Never> in
            if enabled {
                return AdblockManager.shared.$blocklist.eraseToAnyPublisher()
            }
            return Just(nil).eraseToAnyPublisher()
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] list in
            self?.adblockRuleList = list
        }
        .store(in: &subscriptions)

        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #else
        NotificationCenter.default.addObserver(self, selector: #selector(appDidForeground), name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif

        webview.onDarkModeChanged = { [weak self] darkMode in
            guard let self else { return }
            self.colorScheme = darkMode ? .dark : .light // self.webview.colorScheme
        }
        
        // Observe UserDefaults changes for settings
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // Update adblock setting if changed in UserDefaults
                let adblockSetting = DefaultsKeys.adblock.boolValue(defaultValue: false)
                if self.adblockEnabled != adblockSetting {
                    self.adblockEnabled = adblockSetting
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

    public var silenced = false {
        didSet(old) {
            guard silenced != old else { return }
            webview.setAllMediaPlaybackSuspended(silenced, completionHandler: nil)
            webview.setMicrophoneCaptureState(silenced ? .none : .active, completionHandler: nil)
            webview.setCameraCaptureState(silenced ? .none : .active, completionHandler: nil)
            // TODO: Disable going fullscreen
        }
    }

    var transparent: Bool = false {
        didSet(old) {
            if transparent != old { updateTransparency() }
        }
    }

    private func updateTransparency() {
        #if os(iOS)
        if transparent {
            webview.backgroundColor = nil
        } else if autoDarkMode {
            webview.backgroundColor = UIColor(named: "PureBackground")!
        } else {
            webview.backgroundColor = UIColor.white
        }
        webview.isOpaque = !transparent
        #endif
    }

    private var adblockRuleList: WKContentRuleList? {
        didSet(old) {
            // TODO: is the userContentController shared between webviews?
            guard adblockRuleList != old else { return }
            if let old = old {
                webview.configuration.userContentController.remove(old)
            }
            if let list = adblockRuleList {
                webview.configuration.userContentController.add(list)
            }
        }
    }

    public var view: UINSView { webview }

    func goBack() {
        webview.goBack()
    }

    func goForward() {
        webview.goForward()
    }
    
    // func configure(_ block: (WKWebView) -> Void) {
    //     block(webview)
    // }

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
    private var waitingForRepopulationAfterProcessTerminate = false
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

    // MARK: - WKNavigationDelegate
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        needsMetadataRefresh()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        needsMetadataRefresh()
    }
    
    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.webContentWantsToClose(self)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if silenced {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true,
            let delegate {
            let decision = delegate.webContent(self, decidePolicyFor: navigationAction)
            decisionHandler(decision)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let delegate {
            let decision = delegate.webContent(self, decidePolicyForResponse: navigationResponse)
            decisionHandler(decision)
            return
        }
        decisionHandler(.allow)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        waitingForRepopulationAfterProcessTerminate = true
    }

    // MARK: - WKUIDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
//        if let delegate {
//            return delegate.webContent(self, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
//        }

        if let delegate {
            switch delegate.webContent(self, decidePolicyFor: navigationAction) {
            case .cancel, .download:
                return nil
            case .allow: () // Fall thru and allow loading in same tab
            default: return nil // Deny for unknown
            }
        }
        
        let newWebContent = WebContent(id: .assign(), profileUUID: profileUUID, config: configuration)
        if let url = navigationAction.request.url {
            newWebContent.populateWithInitialURL(url)
        }
        
        #if os(macOS)
        let commandPressed = NSEvent.modifierFlags.contains(.command)
        #else
        let commandPressed = false
        #endif
        delegate?.webContent(self, didSpawnNewWebContent: newWebContent, shouldActivate: !commandPressed)
        
        return newWebContent.webview
    }

    // MARK: - Metadata
    private func needsMetadataRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.refreshMetadataNow()
        }
    }

    private func refreshMetadataNow() {
        var info = self.info
        info.url = webview.url
        info.title = webview.title
        info.inferredDarkMode = webview.underPageBackgroundColor.hsba.brightness <= 0.4
        self.info = info
        if injectedCSS != "" || injectedJS != "" || autoDarkMode {
            updateInjectedCode()
        }
    }

    private func refreshAutoDarkMode() {
        guard autoDarkMode else { return }
        info.inferredDarkMode = webview.underPageBackgroundColor.hsba.brightness <= 0.4
        updateInjectedCode()
    }

    // MARK: - CSS Injection
    private func updateInjectedCode() {
        var injectedStyles = [injectedCSS]
        print("[AD] Autodark: \(autoDarkMode), pageDark: \(info.inferredDarkMode), markMode: \(colorScheme == .dark)")
        if autoDarkMode, !info.inferredDarkMode, colorScheme == .dark {
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
