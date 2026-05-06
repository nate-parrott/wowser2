#if os(macOS)
import SwiftUI
import AppKit
import WebKit

struct VSCodeOverlay: View {
    var sessionID: String
    var folder: String?
    var webContent: WebContent
    var isFocused: Bool

    @ObservedObject private var manager = VSCodeServerManager.shared
    @State private var loadFailureCount = 0

    private var paneID: ID<WebContent> { webContent.id }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            switch manager.status {
            case .running(let baseURL):
                let session = sessionForWebContent()
                VSCodeWebViewRepresentable(session: session, targetURL: composedURL(base: baseURL))
                    .onAppearOrChange(of: isFocused) { focused in
                        if focused {
                            DispatchQueue.main.async { session.focus() }
                        }
                    }
            case .starting, .notStarted:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting VS Code…")
                        .foregroundStyle(.secondary)
                    Text("First launch downloads the server (~100 MB).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .failed(let message):
                VSCodeNotInstalledOverlay(message: message) {
                    manager.retry()
                    manager.ensureStarted()
                }
            }
        }
        .onAppear {
            updateTitle()
            manager.ensureStarted()
        }
    }

    private func composedURL(base: URL) -> URL {
        guard let folder, !folder.isEmpty else { return base }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = c.queryItems ?? []
        items.append(URLQueryItem(name: "folder", value: folder))
        c.queryItems = items
        return c.url ?? base
    }

    private func updateTitle() {
        let title: String = {
            if let folder, !folder.isEmpty {
                return (folder as NSString).lastPathComponent
            }
            return "VS Code"
        }()
        BrowserStore.shared.modify { state in
            state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
                pane.info.title = title
            }
        }
    }

    private func sessionForWebContent() -> VSCodeWebSession {
        if let existing = webContent.overlayObject as? VSCodeWebSession {
            return existing
        }
        let s = VSCodeWebSession()
        webContent.overlayObject = s
        return s
    }
}

@MainActor
final class VSCodeWebSession {
    let webView: WKWebView
    private var loadedURL: URL?

    init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
    }

    func loadIfNeeded(_ url: URL) {
        if loadedURL == url { return }
        loadedURL = url
        webView.load(URLRequest(url: url))
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }
}

private struct VSCodeWebViewRepresentable: NSViewRepresentable {
    let session: VSCodeWebSession
    let targetURL: URL

    func makeNSView(context: Context) -> WKWebView {
        session.loadIfNeeded(targetURL)
        return session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        session.loadIfNeeded(targetURL)
    }
}

private struct VSCodeNotInstalledOverlay: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("VS Code isn't available")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            VStack(spacing: 6) {
                Text("Install Visual Studio Code from")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("code.visualstudio.com", destination: URL(string: "https://code.visualstudio.com/")!)
            }
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }
}
#endif
