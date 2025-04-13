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
        WebViewRepresentable(webContent: webContent, shrunk: shouldShrink)
    }
}

#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    var webContent: WebContent
    var shrunk: Bool
    
    func makeNSView(context: Context) -> some NSView {
        let container = WebviewContainer()
        container.webview = webContent.webview
        container.webview?.shrunk = shrunk
        return container
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        if let webview = nsView as? WebviewContainer {
            webview.webview?.shrunk = shrunk
        }
    }
}

#else
// TODO
#endif

// When `elementFullscreen` is enabled, the WKWebview may occasionally take itself out of the view hierarchy to go fullscreen.
// When this is the case, we want to avoid disturbing it.
// We should avoid adding the WKWebView directly to the view hierarchy, because SwiftUI might try to re-mount the view.
// So instead, we put it in a container.

private class WebviewContainer: UINSView {
    var webview: WebContentWebView? {
        didSet {
            if webview !== oldValue {
                if oldValue?.superview == self {
                    oldValue?.removeFromSuperview()
                }
                if let webview {
                    addSubview(webview)
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
