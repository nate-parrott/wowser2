import SwiftUI

// Switches on a NativePageKey and renders the appropriate native overlay.
// Mounted by WrappedWebView when the WKWebView's URL parses into a key.
struct NativePageOverlay: View {
    var key: NativePageKey
    var webContent: WebContent
    var isFocused: Bool

    var body: some View {
        ZStack {
            switch key {
            case .terminal(let id, let cwd):
                #if os(macOS)
                TerminalOverlay(
                    sessionID: id,
                    cwd: cwd,
                    webContent: webContent,
                    isFocused: isFocused
                )
                #else
                Color.clear
                #endif
            case .vscode(let id, let folder):
                #if os(macOS)
                VSCodeOverlay(
                    sessionID: id,
                    folder: folder,
                    webContent: webContent,
                    isFocused: isFocused
                )
                #else
                Color.clear
                #endif
            case .fileBrowser(let id, let path):
                #if os(macOS)
                FileBrowserOverlay(
                    sessionID: id,
                    initialPath: path,
                    webContent: webContent,
                    isFocused: isFocused
                )
                #else
                Color.clear
                #endif
            }
        }
    }
}
