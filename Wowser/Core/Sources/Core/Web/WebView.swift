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
        let webview = webContent.webview
        webview.shrunk = shrunk
        return webview
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        if let webview = nsView as? WebContentWebView {
            webview.shrunk = shrunk
        }
    }
}
#else
// TODO
#endif
