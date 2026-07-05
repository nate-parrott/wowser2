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
            case .terminal(let cwd, let runCommand):
                #if os(macOS)
                TerminalOverlay(
                    cwd: cwd,
                    runCommand: runCommand,
                    webContent: webContent
                )
                #else
                Color.clear
                #endif
            case .vscode(let folder):
                // Real VSCode is loaded directly by the underlying WKWebView.
                // Normally invisible; re-shows the native loading UI if the
                // committed page is serve-web's "downloading…" placeholder.
                #if os(macOS)
                VSCodeWedgeWatcher(folder: folder, webContent: webContent)
                    .id(webContent.id)
                #else
                Color.clear.allowsHitTesting(false)
                #endif
            case .fileBrowser(let path):
                #if os(macOS)
                FileBrowserOverlay(
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
