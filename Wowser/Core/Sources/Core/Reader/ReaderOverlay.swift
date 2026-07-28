import WebKit
import SwiftUI
import Reeeed

struct ReaderOverlay: View {
    var readableDoc: ReadableDoc
    var mainWebContent: WebContent

    @Environment(\.profileID) private var profileID
    @Environment(\.windowID) private var windowID

    @State private var isFindInPageActive = false
    @State private var focusSnap = FocusSnap()
    // TODO: proper profile assignment
    @StateObject private var webContent = WebContentWebKit(id: .assign(), datastoreUUID: UUID())
    @StateObject private var webContentNavDelegate = WebContentNavDelegate()

    private var paneID: ID<WebContent> { mainWebContent.id }

    /// Reader has its own FocusTarget case. Observe `.reader(paneID)` and
    /// focus the internal reader WKWebView. find-in-page within the reader
    /// stays as local view state — it lives only inside this overlay.
    private var focusToken: Date? {
        guard !isFindInPageActive else { return nil }
        return focusSnap.target == .reader(paneID) ? focusSnap.date : nil
    }

    private var isPaneFocused: Bool {
        focusSnap.target?.paneID == paneID
    }

    var body: some View {
        ZStack {
            ReaderThemePref().color(forKey: .background).swiftUI

            WebView(webContent: webContent)
                .onAppearOrChange(of: focusToken, perform: { token in
                    if token != nil {
                        #if os(macOS)
                        webContent.webview.wowser_becomeFirstResponder(asTarget: .reader(paneID))
                        #else
                        webContent.focus()
                        #endif
                    }
                })

            // Find in page overlay
            if isFindInPageActive {
                FindInPageView(
                    webView: webContent.webview,
                    onClose: { isFindInPageActive = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding()
                .transition(.move(edge: .top))
            }

            // Hidden find button for keyboard shortcut
            if isPaneFocused {
                Button("", action: findInPage)
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibility(hidden: true)
            }
        }
        .onReceiveFocusSnap(windowID: windowID) { self.focusSnap = $0 }
        .onAppearOrChange(of: readableDoc) { content in
            let html = readableDoc.html(includeExitReaderButton: false, theme: ReaderThemePref().asTheme)
            webContent.transparent = true
            webContent.populateWithInitialHTML(html, baseURL: content.url)
            webContent.delegate = webContentNavDelegate
            webContentNavDelegate.mainWebContent = mainWebContent
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
}

// We set this as the delegate for our reader webcontent
private class WebContentNavDelegate: ObservableObject, WebContentDelegate {
    weak var mainWebContent: WebContent?
    
    func webContent(_ webContent: WebContent, decidePolicyFor navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .other {
            return .allow // may be initial setup
        }
        if navigationAction.navigationType == .linkActivated {
            // Force navigation in main main webcontent instead
            mainWebContent?.load(request: navigationAction.request)
        }
        return .cancel
    }
    func webContent(_ webContent: WebContent, decidePolicyForResponse navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
        return .allow
    }
    func webContent(_ webContent: WebContent, didSpawnNewWebContent newWebContent: WebContent, shouldActivate: Bool) {
        guard let mainWebContent else { return }
        mainWebContent.delegate?.webContent(mainWebContent, didSpawnNewWebContent: newWebContent, shouldActivate: shouldActivate)
    }
    func webContentWantsToClose(_ webContent: WebContent) {
        // don't really need to implement this one
    }
    func webContent(_ webContent: WebContent, infoDidChange info: WebContent.Info, previous: WebContent.Info?) {
        // no op
    }
    func webContentDidBecomeFirstResponder(_ webContent: WebContent) {
        /// no op
    }
}

//    .onAppearOrChange(of: focusWebview, perform: { focus in
//        if focus {
//            DispatchQueue.main.async {
//                webContent.focus()
//            }
//        }
//    })
//    .id(webContent)
