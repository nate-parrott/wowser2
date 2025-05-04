import SwiftUI
import WebKit
import Combine
import Reeeed

/// A wrapper around WebView that provides additional functionality like find-in-page
public struct WrappedWebView: View {
    var webContent: WebContent
    var isFocused: Bool
    var shrunk: Bool
    
    @State private var isFindInPageActive = false
    @State private var windowWantsWebviewFocus = false
    @Environment(\.windowID) private var windowID
    
    @State private var extractedReaderContent: ReadableDoc?
    
    public var body: some View {
        ZStack {
            receivers
            
            // The base WebView
            WebView(webContent: webContent, shrunk: shrunk)
                .onAppearOrChange(of: focusWebview, perform: { focus in
                    if focus {
                        DispatchQueue.main.async {
                            webContent.focus()
                        }
                    }
                })
                .onAppearOrChange(of: extractedReaderContent != nil, perform: { reader in
                    webContent.silenced = reader
                })
                .id(webContent)
            
            if let extractedReaderContent {
                ReaderOverlay(readableDoc: extractedReaderContent, isFocusedPane: isFocused, windowWantsWebviewFocus: windowWantsWebviewFocus, mainWebContent: webContent)
                    .id(webContent.id)
                    .transition(.opacity)
            } else {
                // Find in page overlay
                if isFindInPageActive, extractedReaderContent == nil {
                    FindInPageView(
                        webView: webContent.webview,
                        onClose: { isFindInPageActive = false }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
                    .transition(.move(edge: .top))
                }
                
                // Hidden find button for keyboard shortcut
                if isFocused, extractedReaderContent == nil {
                    Button("", action: findInPage)
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibility(hidden: true)
                }
            }
        }
        .animation(.niceDefault(duration: 0.15), value: extractedReaderContent != nil)
        .modifier(ByInjectingGeneratedPages(webContent: webContent))
        .animation(.spring(duration: 0.2, bounce: 0.2, blendDuration: 0.1), value: isFindInPageActive)
    }
    
    private var focusWebview: Bool {
        isFocused && !isFindInPageActive && windowWantsWebviewFocus && extractedReaderContent == nil
    }
    
    private func findInPage() {
        if isFindInPageActive {
            let selector = #selector(NSResponder.selectAll(_:))
            NSApp.sendAction(selector, to: nil, from: self)
        } else {
            isFindInPageActive.toggle()
        }
    }
    
    private func cleanModeOptionsChanged(_ options: CleanModeSnapshotForPane) {
        webContent.injectedCSS = options.wantsCSS ?? ""
        webContent.fullContentExtractionMode = options.wantsReader ? .reader : .none
    }
    
    @ViewBuilder private var receivers: some View {
        // Fake view for onreceive
        if let windowID {
            Color.clear.onReceive(BrowserStore.shared.uiPublisher.map({ $0.shouldFocusMainWebContent(forWindowID: windowID) }).removeDuplicates(), perform: { self.windowWantsWebviewFocus = $0 })
                .id(windowID)
        }
        
        Color.clear.onReceive(CleanModeStore.shared.cleanModeSnapshotForPane(id: webContent.id).removeDuplicates(), perform: {
            cleanModeOptionsChanged($0)
        })
        .onReceive(webContent.$fullContentExtractionStatus.map { $0.readerContent }.removeDuplicates(), perform: { self.extractedReaderContent = $0 })
        .id(webContent.id)
    }
}

private extension BrowserState {
    func shouldFocusMainWebContent(forWindowID id: ID<WindowState>) -> Bool {
        if let win = windows[id] {
            return !win.searchOverlayActive
        }
        return false
    }
}
