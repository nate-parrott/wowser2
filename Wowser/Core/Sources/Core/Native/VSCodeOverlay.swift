#if os(macOS)
import SwiftUI
import AppKit

/// Phase shown by the native loading overlay while we wait for VS Code.
private enum VSCodeLoadPhase {
    case starting      // waiting for the serve-web process to bind its port
    case downloading   // serve-web is up but still fetching the server build
}

/// How long to wait before offering the manual "Reset and try again"
/// escape hatch. A healthy cold download can take a while, so we don't
/// nag immediately — but a wedged download would otherwise sit forever.
private let vscodeResetRevealDelay: UInt64 = 12_000_000_000

/// Classifies what serve-web is currently serving. serve-web answers its own
/// "The latest version of the Visual Studio Code Server is downloading,
/// please wait a moment…" placeholder with HTTP 200 (plus a self-reload
/// script), so a status-code check alone can't tell "ready" from "still
/// downloading" — we sniff the body.
enum VSCodeServeWebProbe {
    case unreachable, downloading, ready

    static func probe(_ url: URL) async -> VSCodeServeWebProbe {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode) else {
                return .unreachable
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.localizedCaseInsensitiveContains("is downloading")
                || body.localizedCaseInsensitiveContains("please wait") {
                return .downloading
            }
            return .ready
        } catch {
            return .unreachable
        }
    }
}

/// Owns the polling loop: kicks `VSCodeServerManager.ensureStarted()`,
/// then probes the server until it serves the *actual editor* (not its own
/// "…is downloading, please wait" placeholder page), and only then navigates
/// the webview to the live `http://127.0.0.1:<port>/?folder=…`. Until then we
/// keep a native overlay up so the user never sees the bare placeholder page.
/// Once the nav commits, `info.url` flips to a real serve-web URL,
/// `NativePageKey` becomes `.vscode`, and this overlay unmounts.
struct VSCodeLoadingOverlay: View {
    var folder: String?
    var webContent: WebContent

    @ObservedObject private var manager = VSCodeServerManager.shared
    @State private var pollTask: Task<Void, Never>?
    @State private var resetRevealTask: Task<Void, Never>?
    @State private var phase: VSCodeLoadPhase = .starting
    @State private var showReset = false

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
                VSCodeDownloadingOverlay(
                    phase: phase,
                    showReset: showReset,
                    onReset: reset
                )
            }
        }
        .onAppear {
            manager.ensureStarted()
            startPolling()
            scheduleResetReveal()
        }
        .onDisappear {
            pollTask?.cancel(); pollTask = nil
            resetRevealTask?.cancel(); resetRevealTask = nil
        }
    }

    private func reset() {
        showReset = false
        phase = .starting
        manager.resetAndRestart()
        startPolling()
        scheduleResetReveal()
    }

    private func scheduleResetReveal() {
        resetRevealTask?.cancel()
        resetRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: vscodeResetRevealDelay)
            if !Task.isCancelled { showReset = true }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        let folder = self.folder
        let webContent = self.webContent
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if case .running(let baseURL) = manager.status {
                    switch await VSCodeServeWebProbe.probe(baseURL) {
                    case .ready:
                        webContent.load(url: NativePageKey.vscode(folder: folder).url)
                        return
                    case .downloading:
                        phase = .downloading
                    case .unreachable:
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

/// Mounted over an already-committed `.vscode` tab (via `NativePageOverlay`).
///
/// `VSCodeLoadingOverlay` only guards the *pre-commit* path: it unmounts the
/// moment the webview commits a serve-web URL. But serve-web serves its own
/// "…is downloading, please wait" placeholder with HTTP 200 and a self-reload
/// loop, so a tab can commit and then wedge on that page with no native UI
/// and no escape hatch. This watcher probes the server while the tab is up
/// and re-shows the native overlay + "Reset and try again" whenever the
/// server is stuck serving the placeholder (or has died).
struct VSCodeWedgeWatcher: View {
    var folder: String?
    var webContent: WebContent

    @State private var wedged = false
    @State private var phase: VSCodeLoadPhase = .starting
    @State private var showReset = false
    @State private var pollTask: Task<Void, Never>?
    @State private var resetRevealTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if wedged {
                Color(NSColor.windowBackgroundColor)
                VSCodeDownloadingOverlay(
                    phase: phase,
                    showReset: showReset,
                    onReset: reset
                )
            } else {
                Color.clear.allowsHitTesting(false)
            }
        }
        .onAppear { startPolling() }
        .onDisappear {
            pollTask?.cancel(); pollTask = nil
            resetRevealTask?.cancel(); resetRevealTask = nil
        }
    }

    private func reset() {
        showReset = false
        phase = .starting
        VSCodeServerManager.shared.resetAndRestart()
        scheduleResetReveal()
    }

    private func startPolling() {
        pollTask?.cancel()
        let folder = self.folder
        let webContent = self.webContent
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                switch await VSCodeServeWebProbe.probe(VSCodeConfig.serveWebBaseURL) {
                case .ready:
                    if wedged {
                        // The placeholder self-reloads into the editor
                        // eventually, but load explicitly so recovery is
                        // instant and the folder param is preserved.
                        webContent.load(url: NativePageKey.vscode(folder: folder).url)
                        becomeHealthy()
                    }
                    // Healthy tab: stop watching. A server that dies later
                    // surfaces as a failed nav, which mounts
                    // VSCodeLoadingOverlay via LoadingFailureOverlay.
                    return
                case .downloading:
                    // If the placeholder is being served by an orphan from a
                    // previous app run (our manager owns no process), this
                    // reclaims the port and sweeps stuck `.staging` downloads
                    // — auto-healing without the reset button. No-op while
                    // our own server is legitimately mid-download.
                    VSCodeServerManager.shared.ensureStarted()
                    becomeWedged(phase: .downloading)
                case .unreachable:
                    // Server died out from under a committed tab (e.g. app
                    // relaunch killed it); bring it back up.
                    VSCodeServerManager.shared.ensureStarted()
                    becomeWedged(phase: .starting)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func becomeWedged(phase: VSCodeLoadPhase) {
        self.phase = phase
        if !wedged {
            wedged = true
            scheduleResetReveal()
        }
    }

    private func becomeHealthy() {
        wedged = false
        showReset = false
        resetRevealTask?.cancel(); resetRevealTask = nil
    }

    private func scheduleResetReveal() {
        resetRevealTask?.cancel()
        resetRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: vscodeResetRevealDelay)
            if !Task.isCancelled { showReset = true }
        }
    }
}

/// Native overlay shown while VS Code starts up / downloads its server build.
private struct VSCodeDownloadingOverlay: View {
    var phase: VSCodeLoadPhase
    var showReset: Bool
    var onReset: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(
                    Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(spacing: 6) {
                Text(phase == .downloading ? "Downloading VS Code server…" : "Starting VS Code…")
                    .font(.headline)
                Text("First launch downloads the server (~100 MB). This can take a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            ProgressView()
                .controlSize(.small)

            if showReset {
                VStack(spacing: 8) {
                    Text("Taking longer than expected?")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Reset and try again", action: onReset)
                        .controlSize(.large)
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
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
