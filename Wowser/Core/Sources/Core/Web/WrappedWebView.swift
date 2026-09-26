import SwiftUI
import WebKit
import Combine
import Reeeed

/// A wrapper around WebView that provides additional functionality like find-in-page.
/// Pure observer of the focus system: every focus decision comes from
/// `BrowserState.focusState(windowID:)`. See CLAUDE.md.
public struct WrappedWebView: View {
    var webContent: WebContent
    var shrunk: Bool

    @State private var focusSnap = FocusSnap()
    @Environment(\.windowID) private var windowID

    @State private var extractedReaderContent: ReadableDoc?
    @State private var nativePageKey: NativePageKey?
    @State private var loadingFailure: WebContent.Info.FailedNav?

    public init(webContent: WebContent, shrunk: Bool) {
        self.webContent = webContent
        self.shrunk = shrunk
    }

    public var body: some View {
        ZStack {
            receivers

        WebView(webContent: webContent, shrunk: shrunk)
            .onAppearOrChange(of: webviewFocusToken, perform: { token in
                if token != nil {
                    webContent.focus()
                }
            })
            .onAppearOrChange(of: extractedReaderContent != nil, perform: { reader in
                webContent.silenced = reader
            })
            .id(webContent)
            .overlay(alignment: .topTrailing) {
                findInPageContent
            }
            #if os(macOS)
            .overlay { AutofillOverlay(webContent: webContent) }
            #endif
            .animation(.toastDropCurve, value: isFindInPageActive)

            if let nativePageKey {
                NativePageOverlay(key: nativePageKey, webContent: webContent)
                    .modifier(NewTabAnimation(shrunk: shrunk))
                    .id(nativePageKey)
            } else if let extractedReaderContent {
                ReaderOverlay(readableDoc: extractedReaderContent, mainWebContent: webContent)
                    .id(webContent.id)
            } else if let loadingFailure {
                LoadingFailureOverlay(failure: loadingFailure, webContent: webContent)
                    .modifier(NewTabAnimation(shrunk: shrunk))
            }

            // Above the native overlays so the terminal outline isn't hidden
            // behind the terminal's own background.
            #if os(macOS)
            DictationOverlay(webContent: webContent)
            #endif
        }
        .animation(.niceDefault(duration: 0.3), value: extractedReaderContent != nil)
        .modifier(ByInjectingGeneratedPages(webContent: webContent))
        .animation(.spring(duration: 0.2, bounce: 0.2, blendDuration: 0.1), value: isFindInPageActive)
    }

    /// True iff the focus snap currently designates this pane as focused — used
    /// only to gate visual extras (the hidden Cmd+F button), never to drive focus.
    private var isPaneFocused: Bool {
        focusSnap.target?.paneID == webContent.id
    }

    private var isFindInPageActive: Bool {
        if case .findInPage(let id) = focusSnap.target { return id == webContent.id }
        return false
    }

    /// Non-nil iff the underlying WKWebView should hold first responder right now.
    /// Single rule: target == .webContent(myID). All other gating (reader / native /
    /// find / shrunk / search) is encoded by `focusState` returning a different target.
    private var webviewFocusToken: Date? {
        focusSnap.target == .webContent(webContent.id) ? focusSnap.date : nil
    }

    @ViewBuilder private var findInPageContent: some View {
        if isFindInPageActive, let wkWebview = webContent.wkWebview {
            FindInPageView(
                webView: wkWebview,
                paneID: webContent.id,
                onClose: { closeFindInPage() }
            )
            .padding()
            .transition(.move(edge: .top))
        }

        // Hidden find button for keyboard shortcut. Gated to the focused pane so
        // Cmd+F in a split view only fires once. Suppressed on VS Code tabs, where
        // Cmd+F belongs to the editor's own find.
        if isPaneFocused, extractedReaderContent == nil, nativePageKey?.isVSCode != true {
            Button("", action: toggleFindInPage)
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibility(hidden: true)
        }
    }

    private func toggleFindInPage() {
        #if os(macOS)
        if isFindInPageActive {
            // Already in find — re-fire makes the find field select-all.
            let selector = #selector(NSResponder.selectAll(_:))
            NSApp.sendAction(selector, to: nil, from: nil)
            return
        }
        #endif
        BrowserStore.shared.modify { state in
            state.didFocus(target: .findInPage(webContent.id))
        }
    }

    private func closeFindInPage() {
        BrowserStore.shared.modify { state in
            state.didLoseFocus(target: .findInPage(webContent.id))
        }
    }

    private func cleanModeOptionsChanged(_ options: CleanModeSnapshotForPane) {
        webContent.injectedCSS = options.wantsCSS ?? ""
        webContent.injectedJS = options.wantsJS ?? ""
        webContent.fullContentExtractionMode = options.wantsReader ? .reader : .none
    }

    @ViewBuilder private var receivers: some View {
        if let windowID {
            Color.clear.onReceive(BrowserStore.shared.uiPublisher.map({ $0.focusState(windowID: windowID) }).removeDuplicates(), perform: { self.focusSnap = $0 })
                .id(windowID)
        }

        Color.clear.onReceive(CleanModeStore.shared.cleanModeSnapshotForPane(id: webContent.id).removeDuplicates(), perform: {
            cleanModeOptionsChanged($0)
        })
        .onReceive(webContent.$fullContentExtractionStatus.map { $0.readerContent }.removeDuplicates(), perform: { self.extractedReaderContent = $0 })
        .onReceive(webContent.$info.map { $0.url.flatMap(NativePageKey.init(url:)) }.removeDuplicates(), perform: { self.nativePageKey = $0 })
        .onReceive(webContent.$info.map { $0.failedNavToURL }.removeDuplicates(), perform: { self.loadingFailure = $0 })
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

private struct LoadingFailureOverlay: View {
    var failure: WebContent.Info.FailedNav
    var webContent: WebContent
    
    var body: some View {
        if let nativePage = NativePageKey(url: failure.url), case .vscode(let folder) = nativePage {
            #if os(macOS)
            VSCodeLoadingOverlay(folder: folder, webContent: webContent)
            #else
            Text("VSCode not supported here")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        } else {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "network.slash")
                    .opacity(0.1)
                    .font(.system(size: 100))
                
                HStack {
                    Text("Error :(")
                        .font(.title)
                }
                .font(.system(.caption))
                .frame(maxWidth: 400)
                
                Button(action: {
                    webContent.load(url: failure.url)
                }) {
                    Text("Reload")
                }
                
                Spacer()
                
                HStack {
                    Text(failure.displayString)
                        .lineLimit(1)
                        .help(failure.displayString)
                    
                    CopyButton(text: failure.displayString)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
            .background(.thickMaterial)

        }
    }
}

extension WebContent.Info.FailedNav {
    var displayString: String {
        switch error {
        case .generic(let str): return str
        }
    }
}
