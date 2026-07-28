#if os(macOS)
import SwiftUI
import AppKit
import Combine
import SwiftTerm

struct TerminalOverlay: View {
    var cwd: String?
    var runCommand: String?
    var webContent: WebContent

    private var paneID: ID<WebContent> { webContent.id }

    @AppStorage(DefaultsKeys.hasSeenTerminalUpsell.rawValue) private var hasSeenUpsell: Bool = false
    @AppStorage(DefaultsKeys.mcpServerURL.rawValue) private var mcpURL: String = ""
    @State private var upsellVisible = false
    @State private var focusSnap = FocusSnap()
    @Environment(\.windowID) private var windowID

    private var isFocused: Bool {
        focusSnap.target == .terminal(paneID)
    }

    /// Non-nil iff the SwiftTerm view should hold first responder right now.
    private var focusToken: Date? {
        isFocused ? focusSnap.date : nil
    }

    var body: some View {
        // Pull (or create) the persistent TerminalSession off the WebContent.
        // Lifetime is tied to the WebContent itself: the session survives
        // tab-switches and SwiftUI re-mounts, and gets evicted only when
        // BrowserStore drops the WebContent (i.e. the tab is closed or
        // unloaded).
        let session = sessionForWebContent()

        return ZStack(alignment: .topTrailing) {
            TerminalRepresentable(session: session, paneID: paneID)
                .background(Color.black)
                .onAppearOrChange(of: focusToken) { token in
                    if token != nil {
                        session.view.wowser_becomeFirstResponder(asTarget: .terminal(paneID))
                    }
                }
                .onReceiveFocusSnap(windowID: windowID) { self.focusSnap = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Catch up immediately rather than waiting out the tick we
                    // skipped while backgrounded.
                    session.pollCwdNow()
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
            session.start(cwd: cwd, runCommand: runCommand, paneID: paneID)
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
    let view: WowserTerminalView = WowserTerminalView(frame: .zero)
    private var started = false
    private let delegateBox = TerminalDelegateBox()
    var lastKnownCwd: String? {
        didSet {
            refreshTitle()
            if lastKnownCwd != oldValue {
                writeCwdIntoURL()
            }
        }
    }
    /// Last non-empty title set by the shell or a child via OSC 0/1/2.
    /// Used as the displayed title only while a child app is in the
    /// foreground; when the shell itself is foreground, we override with
    /// the cwd so stale titles ("vim …") don't linger after exit.
    fileprivate var shellSetTitle: String? {
        didSet { if oldValue != shellSetTitle { refreshTitle() } }
    }
    /// Command line of the PTY's foreground process group when it isn't the
    /// shell — e.g. "npm run dev". nil at the prompt. Most long-running
    /// programs never set an OSC title, so this is what names their tab.
    private var foregroundCommand: String? {
        didSet { if oldValue != foregroundCommand { refreshTitle() } }
    }
    /// pgid the `foregroundCommand` was read from, so we only pay for the
    /// argv sysctl when the foreground process actually changes.
    private var foregroundPgid: pid_t?
    /// True when the shell owns the PTY's foreground process group — i.e.
    /// the user is at the prompt with no child app running. Updated on
    /// every cwd poll.
    private var shellIsForeground: Bool = true {
        didSet {
            guard oldValue != shellIsForeground else { return }
            // A child just exited: drop its OSC title so a stale "vim …"
            // doesn't outlive it. (Setting this re-enters refreshTitle.)
            if shellIsForeground { shellSetTitle = nil }
            refreshTitle()
        }
    }
    /// Drives the poll loop. Owned by the session, not the view, so a
    /// backgrounded `npm run dev` tab keeps its title and running-state fresh.
    private var pollTask: Task<Void, Never>?

    init() {
        view.processDelegate = delegateBox
        delegateBox.session = self
        view.onClearRequested = { [weak self] in self?.clearScrollback() }
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

    func start(cwd: String?, runCommand: String? = nil, paneID: ID<WebContent>) {
        self.paneID = paneID
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
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                // Nothing to observe while we're not frontmost; we catch up on
                // the first tick after the user comes back.
                if NSApp?.isActive ?? true { self.pollCwdNow() }
            }
        }
        if let runCommand, !runCommand.isEmpty {
            // Wait briefly for the shell to print its prompt, then type the
            // command + Return as if the user had entered it.
            let line = runCommand + "\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                let bytes = Array(line.utf8)
                self.view.process.send(data: bytes[...])
            }
        }
    }

    /// One-shot refresh of everything we scrape from the kernel: the
    /// foreground process group's cwd, and what (if anything) it's running.
    func pollCwdNow() {
        guard let proc = view.process, proc.running, proc.shellPid > 0 else { return }
        let pid = ProcessCwd.foregroundPid(forMasterFd: proc.childfd, fallback: proc.shellPid)
        if let path = ProcessCwd.cwd(forPid: pid), path != lastKnownCwd {
            lastKnownCwd = path
        }

        let childPgid = ProcessCwd.foregroundChildPgid(masterFd: proc.childfd, shellPid: proc.shellPid)
        if childPgid != foregroundPgid {
            foregroundPgid = childPgid
            foregroundCommand = childPgid.flatMap { ProcessCwd.displayCommand(forPid: $0) }
        }
        // Set last: the didSet above has already published the new command, so
        // the flip to "child running" resolves the title in one pass.
        shellIsForeground = childPgid == nil
    }

    /// Cmd-K: throw away scrollback, and — if we're sitting at the prompt —
    /// clear the viewport too and let the shell redraw its prompt in place.
    /// While a child app owns the PTY (vim, claude) we only trim scrollback:
    /// blanking the viewport would leave its UI half-erased until it happened
    /// to repaint.
    func clearScrollback() {
        // ESC [ 3 J — erase scrollback. Fed to the emulator, not the shell:
        // the shell never asked for it and shouldn't see it as input.
        view.feed(text: "\u{1b}[3J")
        guard shellIsForeground else { return }
        // Ctrl-L. The shell clears the screen and reprints the prompt along
        // with whatever the user had already typed, so the line survives.
        view.send([0x0c])
    }

    /// First-responder observation: KVO on the SwiftTerm view's window so we
    /// notice when the user clicks into the terminal directly. Idempotent —
    /// safe to call from updateNSView. Re-establishes when the view moves
    /// between windows.
    private var firstResponderSubscription: AnyCancellable?
    private var observedTarget: FocusTarget?
    private var windowChangeObserver: NSObjectProtocol?

    func attachFirstResponderObserver(target: FocusTarget) {
        observedTarget = target
        rebindFirstResponderObserver()
        if windowChangeObserver == nil {
            // SwiftTerm's view doesn't post a "moved to window" event in a
            // form we can hook directly, so listen for window-key bumps and
            // rebind. Cheap and correct.
            windowChangeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rebindFirstResponderObserver() }
            }
        }
    }

    private func rebindFirstResponderObserver() {
        firstResponderSubscription?.cancel()
        firstResponderSubscription = nil
        guard let target = observedTarget, let window = view.window else { return }
        let watched = view
        firstResponderSubscription = window.publisher(for: \.firstResponder)
            .removeDuplicates(by: { $0 === $1 })
            .sink { firstResponder in
                let inside = watched.wowser_subtreeContains(firstResponder)
                BrowserStore.shared.modify { state in
                    if inside {
                        state.didFocus(target: target)
                    } else {
                        state.didLoseFocus(target: target)
                    }
                }
            }
    }

    /// Resolve the tab title from current state and write it to BrowserStore.
    /// Rule: at the prompt, show the cwd. While a child app runs, prefer the
    /// title it set over OSC 0/1/2 (claude, vim), and otherwise name it by its
    /// command line ("npm run dev", "caffeinate -d").
    fileprivate func refreshTitle() {
        guard let paneID else { return }
        let cwdTitle = NativePageKey.prettyCwd(lastKnownCwd)
        let title: String? = shellIsForeground
            ? cwdTitle
            : (shellSetTitle ?? foregroundCommand ?? cwdTitle)
        let command = foregroundCommand
        BrowserStore.shared.modify { state in
            state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
                pane.info.title = title
                pane.info.terminalForegroundCommand = command
            }
        }
    }

    /// Persist the live cwd into the pane's URL by navigating the webview to a
    /// new about:blank?... URL. The webview is the source of truth; KVO on
    /// webview.url propagates the new URL into `info.url` automatically.
    fileprivate func writeCwdIntoURL() {
        guard let webContent else { return }
        let newURL = NativePageKey.terminal(cwd: lastKnownCwd, runCommand: nil).url
        if let wkWebview = webContent.wkWebview, wkWebview.url != newURL {
            wkWebview.load(URLRequest(url: newURL))
        }
    }

    func terminate() {
        pollTask?.cancel()
        pollTask = nil
        view.terminate()
    }

    deinit {
        pollTask?.cancel()
        if let obs = windowChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // PTY child gets SIGHUP via SwiftTerm's terminate(); main-actor hop
        // because LocalProcessTerminalView is AppKit-bound.
        let v = self.view
        Task { @MainActor in v.terminate() }
    }
}

/// SwiftTerm's view swallows most keys straight into the PTY. Cmd-K never
/// reaches `keyDown` (it's a key equivalent, and no menu item claims it), so we
/// intercept it here and clear scrollback the way every other terminal does.
final class WowserTerminalView: LocalProcessTerminalView {
    var onClearRequested: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k",
           let onClearRequested,
           // Key equivalents walk the whole view tree, not just the responder
           // chain — a background terminal tab must not eat the window's Cmd-K.
           wowser_subtreeContains(window?.firstResponder)
        {
            onClearRequested()
            return true
        }
        return super.performKeyEquivalent(with: event)
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
    let paneID: ID<WebContent>

    func makeNSView(context: Context) -> NSView {
        // Return the session's stable container. The SwiftTerm view stays
        // pinned inside it across re-mounts so its layer never resets.
        // Wire up first-responder observation: when SwiftTerm's view becomes
        // first responder (user clicked into the terminal), report it so state
        // can update `focusedPaneIdx`.
        session.attachFirstResponderObserver(target: .terminal(paneID))
        return session.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.attachFirstResponderObserver(target: .terminal(paneID))
    }
}
#endif
