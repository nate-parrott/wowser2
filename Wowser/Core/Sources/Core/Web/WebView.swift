import WebKit
import SwiftUI

public struct WebView: View {
    var webContent: WebContent
    var shrunk: Bool

    public init(webContent: WebContent, shrunk: Bool = false) {
        self.webContent = webContent
        self.shrunk = shrunk
    }

    public var body: some View {
        let shouldShrink = shrunk && DefaultsKeys.animateNewTabs.boolValue(defaultValue: true)
        if webContent.wkWebview != nil {
            WebViewRepresentable(webContent: webContent, shrunk: shouldShrink)
        } else {
            #if os(macOS)
            // Non-WebKit engines (Chromium): mount the engine's own view. The
            // shrunk/new-tab animation is a WKWebView-specific CATransform3D
            // trick, so it's skipped here.
            EngineViewRepresentable(webContent: webContent)
            #endif
        }
    }
}

#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    var webContent: WebContent
    var shrunk: Bool

    func makeNSView(context: Context) -> some NSView {
        let container = WebviewContainer()
        container.webview = webContent.wkWebview
        container.shrunk = shrunk
//        container.webview?.shrunk = shrunk
        return container
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {
        if let container = nsView as? WebviewContainer {
            container.shrunk = shrunk
//            webview.webview?.shrunk = shrunk
        }
    }
}

/// Hosts a non-WebKit engine's view (e.g. a Chromium tab's
/// `ChromiumBrowserHostView`) inside a re-mount-safe container, mirroring the
/// WebviewContainer pattern below.
struct EngineViewRepresentable: NSViewRepresentable {
    var webContent: WebContent

    func makeNSView(context: Context) -> EngineViewContainer {
        let container = EngineViewContainer()
        container.hosted = webContent.view
        return container
    }

    func updateNSView(_ nsView: EngineViewContainer, context: Context) {
        nsView.hosted = webContent.view
    }
}

class EngineViewContainer: NSView {
    var hosted: NSView? {
        didSet {
            if hosted !== oldValue {
                if oldValue?.superview == self {
                    oldValue?.removeFromSuperview()
                }
                if let hosted {
                    addSubview(hosted)
                }
            }
        }
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}

#else
struct WebViewRepresentable: UIViewRepresentable {
    var webContent: WebContent
    var shrunk: Bool

    func makeUIView(context: Context) -> WebviewContainer {
        let container = WebviewContainer()
        container.webview = webContent.wkWebview
        container.shrunk = shrunk
        return container
    }

    func updateUIView(_ uiView: WebviewContainer, context: Context) {
        uiView.shrunk = shrunk
    }
}
#endif

// When `elementFullscreen` is enabled, the WKWebview may occasionally take itself out of the view hierarchy to go fullscreen.
// When this is the case, we want to avoid disturbing it.
// We should avoid adding the WKWebView directly to the view hierarchy, because SwiftUI might try to re-mount the view.
// So instead, we put it in a container.

class WebviewContainer: UINSView {
    var webview: WebContentWebView? {
        didSet {
            if webview !== oldValue {
                if oldValue?.superview == self {
                    oldValue?.removeFromSuperview()
                }
                if let webview {
                    addSubview(webview)
                    webview.isHidden = shrunk
                }
            }
        }
    }

    var shrunk: Bool = false {
        didSet {
            if shrunk != oldValue {
                if shrunk {
                    webview?.isHidden = true
                } else {
                    // disabling shrunk
                    webview?.shrunk = true // this is not animated
                    webview?.isHidden = false
                    webview?.shrunk = false // this animates
                }
            }
        }
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        webview?.frame = bounds

    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        webview?.frame = bounds
    }
    #endif
}
