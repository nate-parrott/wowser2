import SwiftUI
import WebKit
import Combine

/// A wrapper around WebView that provides additional functionality like find-in-page
public struct WrappedWebView: View {
    var webContent: WebContent
    var isFocused: Bool
    
    @State private var isFindInPageActive = false
    
    public init(webContent: WebContent, isFocused: Bool) {
        self.webContent = webContent
        self.isFocused = isFocused
    }
    
    public var body: some View {
        ZStack {
            // The base WebView
            WebView(webContent: webContent)
                .id(webContent)
            
            // Find in page overlay
            if isFindInPageActive {
                FindInPageView(
                    webView: webContent.webview,
                    onClose: { isFindInPageActive = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding()
            }
            
            // Hidden find button for keyboard shortcut
            if isFocused {
                Button("", action: findInPage)
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibility(hidden: true)
            }
        }
    }
    
    private func findInPage() {
        if isFindInPageActive {
            let selector = #selector(NSResponder.selectAll(_:))
            NSApp.sendAction(selector, to: nil, from: self)
        } else {
            isFindInPageActive.toggle()
        }
    }
}

