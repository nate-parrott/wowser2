#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm

struct TerminalOverlay: View {
    var sessionID: String
    var cwd: String?
    var webContent: WebContent
    var isFocused: Bool

    private var paneID: ID<WebContent> { webContent.id }

    @AppStorage(DefaultsKeys.hasSeenTerminalUpsell.rawValue) private var hasSeenUpsell: Bool = false
    @AppStorage(DefaultsKeys.mcpServerURL.rawValue) private var mcpURL: String = ""
    @State private var upsellVisible = false
    @State private var lastBecameKeyAt: Date?
    @State private var appActive: Bool = NSApp?.isActive ?? true
    @Environment(\.windowID) private var windowID

    private struct FocusSnap: Equatable {
        var isFocused: Bool
        var lastBecameKeyAt: Date?
    }
    private var focusSnap: FocusSnap {
        FocusSnap(isFocused: isFocused, lastBecameKeyAt: lastBecameKeyAt)
    }

    /// Drives the cwd-polling task. We poll only when the pane is focused
    /// (i.e. the frontmost tab + frontmost pane) AND the app is active.
    private struct PollKey: Equatable {
        var focused: Bool
        var appActive: Bool
    }
    private var pollKey: PollKey {
        PollKey(focused: isFocused, appActive: appActive)
    }

    var body: some View {
        // Pull (or create) the persistent TerminalSession off the WebContent.
        // Lifetime is tied to the WebContent itself: the session survives
        // tab-switches and SwiftUI re-mounts, and gets evicted only when
        // BrowserStore drops the WebContent (i.e. the tab is closed or
        // unloaded).
        let session = sessionForWebContent()

        return ZStack(alignment: .topTrailing) {
            TerminalRepresentable(session: session)
                .background(Color.black)
                .onAppearOrChange(of: focusSnap) { snap in
                    // Defer to the next runloop tick: WrappedWebView's webview-focus
                    // path is also async, and may fire briefly before nativePageKey
                    // is set (focusing the webview). We need to run after that so
                    // the terminal ends up as first responder.
                    if snap.isFocused {
                        DispatchQueue.main.async { session.focus() }
                    }
                }
                .onReceive(BrowserStore.shared.uiPublisher.map { state -> Date? in
                    guard let windowID else { return nil }
                    return state.windows[windowID]?.lastBecameKeyAt
                }.removeDuplicates()) { self.lastBecameKeyAt = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appActive = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    appActive = false
                }
                .task(id: pollKey) {
                    guard pollKey.focused, pollKey.appActive else { return }
                    // Poll once immediately (handles the first-mount case),
                    // then every second while the gate stays open. Cancelled
                    // automatically when `pollKey` changes or the view goes
                    // away.
                    session.pollCwdNow()
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { break }
                        session.pollCwdNow()
                    }
                }

            if upsellVisible {
                FirstTerminalUpsell(mcpURL: mcpURL) {
                    hasSeenUpsell = true
                    upsellVisible = false
                }
                .padding(20)
                .frame(maxWidth: 420)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .onAppear {
            session.start(sessionID: sessionID, cwd: cwd, paneID: paneID)
            if !hasSeenUpsell {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    upsellVisible = true
                }
            }
        }
        // No `onDisappear { session.terminate() }`: the session is owned by
        // WebContent and will be cleaned up when WebContent itself goes away
        // (deinit in TerminalSession terminates the PTY).
    }

    private func sessionForWebContent() -> TerminalSession {
        if let existing = webContent.overlayObject as? TerminalSession {
            return existing
        }
        let s = TerminalSession()
        s.webContent = webContent
        webContent.overlayObject = s
        return s
    }
}

@MainActor
final class TerminalSession: ObservableObject {
    /// Stable container that SwiftUI's NSViewRepresentable mounts. Pinning
    /// the inner SwiftTerm view here means *its* superview never changes
    /// across tab re-mounts — only this container moves between SwiftUI
    /// host views. That's important: when the SwiftTerm view's superview
    /// changes, its Metal-backed layer flashes / re-initializes, which
    /// visually looks like the terminal "got recreated" on tab switch back.
    let containerView: NSView = NSView(frame: .zero)
    let view: LocalProcessTerminalView = LocalProcessTerminalView(frame: .zero)
    private var started = false
    private let delegateBox = TerminalDelegateBox()
    var lastKnownCwd: String? {
        didSet {
            refreshTitle()
            if lastKnownCwd != oldValue { writeCwdIntoURL() }
        }
    }
    /// The session's stable terminal id (matches `NativePageKey.terminal.id`),
    /// captured when `start` runs so we can rebuild the URL on cwd changes.
    private var sessionID: String?
    /// Last non-empty title set by the shell or a child via OSC 0/1/2.
    /// Used as the displayed title only while a child app is in the
    /// foreground; when the shell itself is foreground, we override with
    /// the cwd so stale titles ("vim …") don't linger after exit.
    fileprivate var shellSetTitle: String? {
        didSet { if oldValue != shellSetTitle { refreshTitle() } }
    }
    /// True when the shell owns the PTY's foreground process group — i.e.
    /// the user is at the prompt with no child app running. Updated on
    /// every cwd poll.
    private var shellIsForeground: Bool = true {
        didSet { if oldValue != shellIsForeground { refreshTitle() } }
    }

    init() {
        view.processDelegate = delegateBox
        delegateBox.session = self
        containerView.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed black so the inset around the SwiftTerm view shows as
        // a clean margin rather than the window background bleeding through.
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)
        // SwiftTerm has no public padding/inset API, so we inset via Auto
        // Layout. 6pt all around.
        let inset: CGFloat = 6
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -inset),
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -inset),
        ])
    }

    /// Pane that owns this session — used to write the terminal title back
    /// to BrowserState when escape sequences set it.
    var paneID: ID<WebContent>?
    weak var webContent: WebContent?

    func start(sessionID: String, cwd: String?, paneID: ID<WebContent>) {
        self.paneID = paneID
        self.sessionID = sessionID
        guard !started else { return }
        started = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolvedCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        lastKnownCwd = resolvedCwd
        // Force the initial title write — the didSet on lastKnownCwd may
        // be a no-op the first time if paneID was nil before this call.
        refreshTitle()
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: nil,
            currentDirectory: resolvedCwd
        )
    }

    /// One-shot cwd refresh, driven by the view layer. Reads the kernel's
    /// view of the foreground process group's cwd and updates
    /// `lastKnownCwd` if it changed.
    func pollCwdNow() {
        guard let proc = view.process, proc.running, proc.shellPid > 0 else { return }
        let pid = ProcessCwd.foregroundPid(forMasterFd: proc.childfd, fallback: proc.shellPid)
        if let path = ProcessCwd.cwd(forPid: pid), path != lastKnownCwd {
            lastKnownCwd = path
        }
        shellIsForeground = ProcessCwd.isShellInForeground(masterFd: proc.childfd, shellPid: proc.shellPid)
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// Resolve the tab title from current state and write it to BrowserStore.
    /// Rule: when the shell is the foreground process (no app running) or
    /// no shell-set title exists, show the cwd. Otherwise show the
    /// app-set OSC title.
    fileprivate func refreshTitle() {
        guard let paneID else { return }
        let title: String?
        if shellIsForeground || shellSetTitle == nil {
            title = TerminalSession.formatCwdForTitle(lastKnownCwd)
        } else {
            title = shellSetTitle
        }
        BrowserStore.shared.modify { state in
            state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
                pane.info.title = title
            }
        }
    }

    /// Persist the live cwd into the pane's URL so a restored session lands
    /// where the user left off. The URL only feeds restore; the live webview
    /// keeps its original about:blank load (refreshMetadataNow leaves info.url
    /// alone for native tabs, so this sticks).
    fileprivate func writeCwdIntoURL() {
        guard let sessionID, let webContent else { return }
        webContent.setNativeOverlayURL(NativePageKey.terminal(id: sessionID, cwd: lastKnownCwd).url)
    }

    static func formatCwdForTitle(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd == "/" { return "/" }
        // Last path component looks tidy in narrow tab strips.
        return (cwd as NSString).lastPathComponent
    }

    func terminate() {
        view.terminate()
    }

    deinit {
        // PTY child gets SIGHUP via SwiftTerm's terminate(); main-actor hop
        // because LocalProcessTerminalView is AppKit-bound.
        let v = self.view
        Task { @MainActor in v.terminate() }
    }
}

private final class TerminalDelegateBox: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let session = self.session
        Task { @MainActor in
            // Store the OSC-set title; resolution to the visible tab title
            // happens in refreshTitle() based on whether the shell is
            // currently foreground.
            session?.shellSetTitle = title.isEmpty ? nil : title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        // Hop back to the main actor; SwiftTerm calls this from the IO queue.
        let session = self.session
        Task { @MainActor in session?.lastKnownCwd = directory }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

private struct FirstTerminalUpsell: View {
    var mcpURL: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                Text("New: Terminal tabs")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            Text("This is a real shell, running in the same browser process as your tabs. Run `claude` to start an agent that can drive the browser via the local MCP server.")
                .font(.callout)
            if !mcpURL.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP server").font(.caption).foregroundStyle(.secondary)
                    Text(mcpURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Text("Settings → MCP for client config snippets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        // Return the session's stable container. The SwiftTerm view stays
        // pinned inside it across re-mounts so its layer never resets.
        return session.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
