import SwiftUI

public struct WebView: View {
    var webContent: WebContent
    var hiddenBecauseEmpty: Bool
    
    public init(webContent: WebContent, hiddenBecauseEmpty: Bool = false) {
        self.webContent = webContent
        self.hiddenBecauseEmpty = hiddenBecauseEmpty
    }
    
    public var body: some View {
        WebViewRepresentable(webContent: webContent, hiddenBecauseEmpty: hiddenBecauseEmpty)
    }
}

#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    var webContent: WebContent
    var hiddenBecauseEmpty: Bool
    
    func makeNSView(context: Context) -> some NSView {
        let webview = webContent.webview
        webview.hiddenBecauseEmpty = hiddenBecauseEmpty
        return webview
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        if let webview = nsView as? WebContentWebView {
            webview.hiddenBecauseEmpty = hiddenBecauseEmpty
        }
    }
}
#else
// TODO
#endif
