import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

/// Decides which branch (if any) draws each window, and keeps track of the
/// engines that are running.
///
/// - `activeBranch` is the user's choice for all normal windows
///   (`DefaultsKeys.shellBranch`; empty = the built-in UI).
/// - A *preview* window runs a specific branch regardless, so a change can be
///   tried next to the UI you're actually using.
@Observable
public final class ShellRouter {
    public static let shared = ShellRouter()

    public private(set) var activeBranch: String?
    public private(set) var previewBranches: [ID<WindowState>: String] = [:]
    /// Set when the last launch never got past loading a branch; that branch
    /// is turned off and this explains why in Settings.
    public private(set) var disabledAfterCrash: String?

    @ObservationIgnored private var engines: [ID<WindowState>: ShellEngine] = [:]
    #if os(macOS)
    @ObservationIgnored private var keyMonitor: Any?
    #endif

    private init() {
        let stored = DefaultsKeys.shellBranch.stringValue().nilIfEmpty
        // If a branch was mid-load when the app last died (a hang the
        // watchdog couldn't break, or a crash), don't walk into it again.
        if let stuck = DefaultsKeys.shellStartingBranch.stringValue().nilIfEmpty {
            DefaultsKeys.shellStartingBranch.setString("")
            if stuck == stored {
                DefaultsKeys.shellBranch.setString("")
                disabledAfterCrash = stuck
                activeBranch = nil
                return
            }
        }
        activeBranch = stored
    }

    /// Call once at launch: installs the bundled branches.
    public func bootstrap() {
        DispatchQueue.global(qos: .userInitiated).async {
            ShellBranchStore.shared.seedIfNeeded()
        }
    }

    /// The branch that should draw `windowID`, or nil for the built-in UI.
    public func branch(for windowID: ID<WindowState>) -> String? {
        if let preview = previewBranches[windowID] { return preview }
        return activeBranch
    }

    public func setActiveBranch(_ name: String?) {
        let value = name?.nilIfEmpty
        DefaultsKeys.shellBranch.setString(value ?? "")
        disabledAfterCrash = nil
        activeBranch = value
    }

    public func setPreview(branch: String?, for windowID: ID<WindowState>) {
        previewBranches[windowID] = branch
    }

    public func isPreview(_ windowID: ID<WindowState>) -> Bool {
        previewBranches[windowID] != nil
    }

    // MARK: Engines

    public func engine(for windowID: ID<WindowState>) -> ShellEngine? {
        engines[windowID]
    }

    public var runningEngines: [ShellEngine] { Array(engines.values) }

    func register(_ engine: ShellEngine) {
        engines[engine.windowID] = engine
        installKeyMonitorIfNeeded()
    }

    func unregister(_ engine: ShellEngine) {
        if engines[engine.windowID] === engine { engines.removeValue(forKey: engine.windowID) }
    }

    /// Bracket a branch load so a load that never returns is noticed at the
    /// next launch.
    func willStart(_ engine: ShellEngine) {
        guard engine.branch == activeBranch else { return }
        DefaultsKeys.shellStartingBranch.setString(engine.branch)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            DefaultsKeys.shellStartingBranch.setString("")
        }
    }

    // MARK: Web content hooks

    /// The engine drawing the window that shows `paneID`, if it listens for `event`.
    private func listener(for paneID: ID<WebContent>, event: String) -> ShellEngine? {
        guard !engines.isEmpty else { return nil }
        guard let windowID = BrowserStore.shared.model.windowContaining(webContentId: paneID)?.id,
              let engine = engines[windowID], engine.listening.contains(event)
        else { return nil }
        return engine
    }

    public enum NavigationVerdict {
        case allow
        case cancel
        case redirect(URL)
    }

    /// Ask the window's branch about a main-frame navigation (`on("navigate")`).
    public func navigationVerdict(paneID: ID<WebContent>, url: URL, userInitiated: Bool) -> NavigationVerdict {
        guard let engine = listener(for: paneID, event: "navigate") else { return .allow }
        let state = BrowserStore.shared.model
        let tabID: ShellJSON = state.paneToTabMapping[paneID].map { ShellJSON.string($0.raw) } ?? .null
        let reply = engine.emit("navigate", [
            "paneId": .string(paneID.raw),
            "tabId": tabID,
            "url": .string(url.absoluteString),
            "isUserInitiated": .bool(userInitiated),
        ])
        if reply?["cancel"]?.bool == true { return .cancel }
        if let target = reply?["redirect"]?.string.flatMap({ URL(string: $0) }), target != url { return .redirect(target) }
        return .allow
    }

    /// A pane finished loading (`on("load")`).
    public func didFinishLoad(paneID: ID<WebContent>, info: WebContent.Info) {
        guard let engine = listener(for: paneID, event: "load"), let url = info.url else { return }
        let title: ShellJSON = info.title.map { ShellJSON.string($0) } ?? .null
        engine.emit("load", ["paneId": .string(paneID.raw), "url": .string(url.absoluteString), "title": title])
    }

    // MARK: Hotkeys

    private func installKeyMonitorIfNeeded() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  let engine = self.engines.values.first(where: { $0.hostWindow === window }),
                  let combo = ShellHotkey(event: event)
            else { return event }
            for command in engine.commands.values {
                if let hotkey = command.hotkey, ShellHotkey(string: hotkey) == combo, engine.runCommand(command.id) {
                    return nil
                }
            }
            return event
        }
        #endif
    }
}

/// A key combination such as "cmd+shift+k".
struct ShellHotkey: Equatable {
    var key: String
    var cmd = false
    var shift = false
    var alt = false
    var ctrl = false

    init?(string: String) {
        var key: String?
        for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "meta": cmd = true
            case "shift": shift = true
            case "alt", "option", "opt": alt = true
            case "ctrl", "control": ctrl = true
            case "": continue
            default: key = part
            }
        }
        guard let key else { return nil }
        self.key = key == "return" ? "enter" : (key == "esc" ? "escape" : key)
    }

    #if os(macOS)
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        cmd = flags.contains(.command)
        shift = flags.contains(.shift)
        alt = flags.contains(.option)
        ctrl = flags.contains(.control)
        // Plain typing is never a hotkey.
        guard cmd || alt || ctrl || event.keyCode == 53 || (122...126).contains(Int(event.keyCode)) else { return nil }
        switch event.keyCode {
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 36, 76: key = "enter"
        case 48: key = "tab"
        case 49: key = "space"
        case 51: key = "backspace"
        case 53: key = "escape"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
            key = chars
        }
    }
    #endif
}

// MARK: - Views

/// Picks between a branch's UI and the built-in one for a window. Put it
/// where the built-in window content would go.
public struct ShellWindowHost<Native: View>: View {
    let windowID: ID<WindowState>
    @ViewBuilder var native: () -> Native

    public init(windowID: ID<WindowState>, @ViewBuilder native: @escaping () -> Native) {
        self.windowID = windowID
        self.native = native
    }

    public var body: some View {
        if let branch = ShellRouter.shared.branch(for: windowID) {
            ShellWindowView(windowID: windowID, branch: branch, native: native)
                // A different branch is a different UI: start from scratch.
                .id(branch)
        } else {
            native()
        }
    }
}

/// Runs one branch for one window. If the branch can't be shown, the
/// built-in UI takes over with a banner explaining what happened — a broken
/// customisation never leaves you without a browser.
struct ShellWindowView<Native: View>: View {
    let windowID: ID<WindowState>
    let branch: String
    @ViewBuilder var native: () -> Native

    @State private var engine: ShellEngine
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFullscreen) private var isFullscreen
    @Environment(\.scenePhase) private var scenePhase

    init(windowID: ID<WindowState>, branch: String, @ViewBuilder native: @escaping () -> Native) {
        self.windowID = windowID
        self.branch = branch
        self.native = native
        _engine = State(initialValue: ShellEngine(branch: branch, windowID: windowID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let failure = engine.failure {
                native()
                ShellFailureBanner(engine: engine, failure: failure)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                ShellTreeView(engine: engine)
                    .modifier(ShellWindowChrome(windowID: windowID))
            }
            ShellInspectorOverlay(engine: engine)
        }
        .environment(engine)
        .environment(\.windowID, windowID)
        .background {
            #if os(macOS)
            WindowAccessor { window in
                if engine.hostWindow !== window { engine.hostWindow = window }
            }
            #endif
        }
        .onAppear {
            engine.isDark = colorScheme == .dark
            engine.isFullscreen = isFullscreen
            ShellRouter.shared.register(engine)
            ShellRouter.shared.willStart(engine)
            engine.start()
        }
        .onDisappear {
            ShellRouter.shared.unregister(engine)
            engine.stop()
        }
        .onChange(of: colorScheme) { _, scheme in engine.isDark = scheme == .dark }
        .onChange(of: isFullscreen) { _, value in engine.isFullscreen = value }
        .onChange(of: scenePhase) { _, phase in engine.isKey = phase == .active }
    }
}

/// The window-wide context the built-in `WindowContent` provides: the space's
/// accent colour, its forced light / dark scheme, and full-bleed layout.
private struct ShellWindowChrome: ViewModifier {
    let windowID: ID<WindowState>

    private struct Snapshot: Equatable {
        var profileID: ID<Profile>
        var theme: SpaceTheme?
        var imageInfo: SpaceImageInfo?
    }

    func body(content: Content) -> some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Snapshot in
            let profileID = state.windows[windowID]?.profile ?? .defaultProfile
            let profile = state.profiles[profileID]
            let showSpaceLook = state.windows[windowID]?.showingNewProfilePage != true
            return Snapshot(profileID: profileID, theme: showSpaceLook ? profile?.theme : nil, imageInfo: showSpaceLook ? profile?.imageInfo : nil)
        }) { snapshot in
            let accent = SpaceAccent.forSpace(theme: snapshot.theme, imageInfo: snapshot.imageInfo) ?? .system
            content
                .environment(\.profileID, snapshot.profileID)
                .tint(accent.accent)
                .accentColor(accent.accent)
                .environment(\.onAccentColor, accent.onAccent)
                .edgesIgnoringSafeArea(.all)
                .modifier(SpaceUISchemeOverride(prefersDarkUI: snapshot.imageInfo?.prefersDarkUI))
        }
    }
}

/// The node tree of an engine's main root.
struct ShellTreeView: View {
    let engine: ShellEngine

    var body: some View {
        Group {
            if let root = engine.tree.roots[ShellEngine.rootKey] {
                ShellNodeView(node: root)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(ShellCoordinateSpace.root))
        .font(.system(size: 13))
    }
}

/// Shown over the built-in UI when a branch failed to load or its root threw.
struct ShellFailureBanner: View {
    let engine: ShellEngine
    let failure: ShellErrorInfo
    @State private var showDetails = false
    @State private var canUndo = false
    @State private var hasGood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(engine.branch)” couldn’t be shown, so this is the built-in UI.")
                        .font(.system(size: 13, weight: .semibold))
                    Text(failure.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(showDetails ? nil : 2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if showDetails {
                ScrollView {
                    Text(failure.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
            HStack(spacing: 8) {
                if canUndo {
                    Button("Undo Last Change") { run { _ = try ShellBranchStore.shared.undo(branch: engine.branch) } }
                }
                if hasGood {
                    Button("Restore Last Working Version") { run { try ShellBranchStore.shared.restoreGood(branch: engine.branch) } }
                }
                Button("Fix with Agent") { ShellFixIt.askAgent(engine: engine, failure: failure) }
                Button("Reload") { engine.reload() }
                Spacer(minLength: 0)
                Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                if ShellRouter.shared.isPreview(engine.windowID) == false {
                    Button("Use Built-in UI") { ShellRouter.shared.setActiveBranch(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        // Disk state is read once here, not in `body`.
        .task(id: failure.id) {
            let branch = engine.branch
            let info = await Task.detached { (ShellBranchStore.shared.info(for: branch).canUndo, ShellBranchStore.shared.hasGoodVersion(branch: branch)) }.value
            canUndo = info.0
            hasGood = info.1
        }
    }

    /// Store changes post a notification the engine reloads on.
    private func run(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            BrowserStore.shared.modify { $0.addToast(message: error.localizedDescription, icon: "exclamationmark.triangle", in: engine.windowID) }
        }
    }
}

enum ShellFixIt {
    /// Hand a branch error to the in-browser agent, with enough context to
    /// find and fix it.
    static func askAgent(engine: ShellEngine, failure: ShellErrorInfo) {
        let dir = ShellBranchStore.shared.directory(for: engine.branch).path
        let prompt = """
        My customised browser UI (shell branch "\(engine.branch)", files in \(dir)) failed with this error. \
        Read the shell guide (shell_docs), find the cause in the branch's files, fix it with shell_write_files, \
        and check it with shell_check before telling me it's fixed.

        \(failure.summary)
        """
        AgentChatTabs.ask(query: prompt, windowID: engine.windowID)
    }
}
