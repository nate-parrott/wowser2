import SwiftUI

// Switches on a NativePageKey and renders the appropriate native overlay.
// Mounted by WrappedWebView when the WKWebView's URL parses into a key.
// Each overlay observes `BrowserState.focusState` itself — no isFocused prop here.
struct NativePageOverlay: View {
    var key: NativePageKey
    var webContent: WebContent

    var body: some View {
        ZStack {
            switch key {
            case .terminal(let id, let cwd, let runCommand):
                #if os(macOS)
                TerminalOverlay(
                    sessionID: id,
                    cwd: cwd,
                    runCommand: runCommand,
                    webContent: webContent
                )
                #else
                Color.clear
                #endif
            case .vscode(let id, let folder):
                #if os(macOS)
                VSCodeOverlay(
                    sessionID: id,
                    folder: folder,
                    webContent: webContent
                )
                #else
                Color.clear
                #endif
            case .fileBrowser(let id, let path):
                #if os(macOS)
                FileBrowserOverlay(
                    sessionID: id,
                    initialPath: path,
                    webContent: webContent
                )
                #else
                Color.clear
                #endif
            }
        }
    }
}
