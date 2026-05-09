#if os(macOS)
import SwiftUI
import AppKit

/// Loading-state overlay for VSCode tabs. Mounted only for
/// `NativePageKey.vscodeLoading` — i.e., the WKWebView committed to the
/// `about:blank?native=vscode-loading&folder=…` sentinel URL because the
/// real serve-web URL couldn't load yet.
///
/// Owns the polling loop: kicks `VSCodeServerManager.ensureStarted()`,
/// then probes the server's HTTP listener until it responds, and finally
/// navigates the webview to the live `http://127.0.0.1:<port>/?folder=…`.
/// Once that nav commits, `info.url` flips to a real serve-web URL,
/// `NativePageKey` becomes `.vscode`, and this overlay unmounts.
struct VSCodeLoadingOverlay: View {
    var folder: String?
    var webContent: WebContent

    @ObservedObject private var manager = VSCodeServerManager.shared
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            switch manager.status {
            case .failed(let message):
                VSCodeNotInstalledOverlay(message: message) {
                    manager.retry()
                    manager.ensureStarted()
                }
            case .notStarted, .starting, .running:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting VS Code…")
                        .foregroundStyle(.secondary)
                    Text("First launch downloads the server (~100 MB).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            manager.ensureStarted()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        let folder = self.folder
        let webContent = self.webContent
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if case .running(let baseURL) = manager.status,
                   await Self.probe(baseURL) {
                    webContent.load(url: NativePageKey.vscode(folder: folder).url)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (200...399).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
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
