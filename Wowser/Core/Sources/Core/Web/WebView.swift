import SwiftUI

public struct WebView: View {
    var webContent: WebContent
    
    public init(webContent: WebContent) {
        self.webContent = webContent
    }
    
    public var body: some View {
        WebViewRepresentable(webContent: webContent)
    }
}

#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    var webContent: WebContent
    func makeNSView(context: Context) -> some NSView {
        webContent.webview
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        
    }
}
#else
// TODO
#endif
