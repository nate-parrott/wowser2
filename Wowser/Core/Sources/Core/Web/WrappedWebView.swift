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
    @State private var windowWebFocus = WindowWebFocusSignal()
    @Environment(\.windowID) private var windowID

    @State private var extractedReaderContent: ReadableDoc?
    @State private var nativePageKey: NativePageKey?

    public var body: some View {
        ZStack {
            receivers

            ZStack {
                // The base WebView
                WebView(webContent: webContent, shrunk: shrunk)
                    .onAppearOrChange(of: focusWebview, perform: { snap in
                        if snap.enabled {
                            DispatchQueue.main.async {
                                webContent.focus()
                            }
                        }
                    })
                    .onAppearOrChange(of: extractedReaderContent != nil, perform: { reader in
                        webContent.silenced = reader
                    })
                    .id(webContent)

                findInPageContent
            }

            if let extractedReaderContent {
                ReaderOverlay(readableDoc: extractedReaderContent, isFocusedPane: isFocused, windowWantsWebviewFocus: windowWebFocus.enabled, mainWebContent: webContent)
                    .id(webContent.id)
//                    .transition(.asymmetric(insertion: .wipeAway.animation(.niceDefault.delay(0.5)), removal: .opacity))
            }

            if let nativePageKey {
                NativePageOverlay(key: nativePageKey, webContent: webContent, isFocused: isFocused)
                    .modifier(NewTabAnimation(shrunk: shrunk))
                    .id(nativePageKey)
            }
        }
        .animation(.niceDefault(duration: 0.3), value: extractedReaderContent != nil)
        .modifier(ByInjectingGeneratedPages(webContent: webContent))
        .animation(.spring(duration: 0.2, bounce: 0.2, blendDuration: 0.1), value: isFindInPageActive)
    }
    
    private var focusWebview: WindowWebFocusSignal {
        let enabled = isFocused && !isFindInPageActive && windowWebFocus.enabled
            && extractedReaderContent == nil && nativePageKey == nil && !shrunk
        return WindowWebFocusSignal(enabled: enabled, lastBecameKeyAt: windowWebFocus.lastBecameKeyAt)
    }
    
    @ViewBuilder private var findInPageContent: some View {
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
    
    private func findInPage() {
        #if os(macOS)
        if isFindInPageActive {
            let selector = #selector(NSResponder.selectAll(_:))
            NSApp.sendAction(selector, to: nil, from: self)
        } else {
            isFindInPageActive.toggle()
        }
        #else
        isFindInPageActive.toggle()
        #endif
    }
    
    private func cleanModeOptionsChanged(_ options: CleanModeSnapshotForPane) {
        webContent.injectedCSS = options.wantsCSS ?? ""
        webContent.fullContentExtractionMode = options.wantsReader ? .reader : .none
    }
    
    @ViewBuilder private var receivers: some View {
        // Fake view for onreceive
        if let windowID {
            Color.clear.onReceive(BrowserStore.shared.uiPublisher.map({ $0.windowWebFocusSignal(forWindowID: windowID) }).removeDuplicates(), perform: { self.windowWebFocus = $0 })
                .id(windowID)
        }

        Color.clear.onReceive(CleanModeStore.shared.cleanModeSnapshotForPane(id: webContent.id).removeDuplicates(), perform: {
            cleanModeOptionsChanged($0)
        })
        .onReceive(webContent.$fullContentExtractionStatus.map { $0.readerContent }.removeDuplicates(), perform: { self.extractedReaderContent = $0 })
        .onReceive(webContent.$info.map { $0.url.flatMap(NativePageKey.init(url:)) }.removeDuplicates(), perform: { self.nativePageKey = $0 })
        .id(webContent.id)
    }
}

// This version of the anim is applied for NATIVE OVERLAYS; the actual webview must be scaled by applying a CATransform3D to the WKWebView because SwiftUI's scaleEffect borks WKWebView layout
private struct NewTabAnimation: ViewModifier {
    var shrunk: Bool
    
    @AppStorage(DefaultsKeys.animateNewTabs.rawValue) private var animateNewTabs = false
    
    func body(content: Content) -> some View {
        let shrink = shrunk && animateNewTabs
        
        content
            .scaleEffect(shrink ? 0.05 : 1)
            .animation(shrink ? nil : .niceDefault(duration: 0.3), value: shrink)
    }
}

/// Snapshot driving webview focus. `enabled` reflects whether the window
/// currently wants the webview to hold first responder; `lastBecameKeyAt`
/// is a token that bumps when the window becomes key, so an unchanged
/// `enabled` value still triggers `.onAppearOrChange` (re-focus on key).
struct WindowWebFocusSignal: Equatable {
    var enabled: Bool = false
    var lastBecameKeyAt: Date?
}

private extension BrowserState {
    func windowWebFocusSignal(forWindowID id: ID<WindowState>) -> WindowWebFocusSignal {
        guard let win = windows[id] else { return WindowWebFocusSignal() }
        return WindowWebFocusSignal(enabled: !win.searchOverlayActive, lastBecameKeyAt: win.lastBecameKeyAt)
    }
}
