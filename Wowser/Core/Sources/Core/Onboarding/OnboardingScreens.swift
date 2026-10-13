#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Welcome

struct OnboardingWelcomeScreen: View {
    var next: () -> Void

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to Wowser")
                    .font(.system(size: 48, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("A single place to work")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .bottomLeading)
        }, footer: {
            Button("Get started", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }
}

// MARK: - Default browser

struct OnboardingDefaultBrowserScreen: View {
    var next: () -> Void

    @State private var isDefault = false

    var body: some View {
        OnboardingScreen(content: {
            OnboardingHeader(
                title: "Set as default browser?",
                subtitle: isDefault ? "Wowser is already your default browser." : "Links you open in other apps will open in Wowser."
            )
        }, footer: {
            Button(isDefault ? "Continue" : "Set as Default") {
                if !isDefault { DefaultBrowser.makeDefault() }
                next()
            }
            .keyboardShortcut(.defaultAction)
            if !isDefault {
                Button("Not yet", action: next)
                    .buttonStyle(OnboardingButtonStyle(primary: false))
            }
        })
        .task {
            isDefault = await Task.detached { DefaultBrowser.isDefault() }.value
        }
    }
}

// MARK: - AI

enum OnboardingAIChoice: Hashable {
    case claude
    case codex
}

/// Kept in `OnboardingModel` so it survives tab switches.
struct OnboardingAIState {
    var choice: OnboardingAIChoice? = .claude
    var installing = false
    var installError: String?
}

struct OnboardingAIScreen: View {
    @Binding var state: OnboardingAIState
    var next: () -> Void

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(
                    title: "Connect your AI",
                    subtitle: "Use your existing AI subscription from the browser, for answering quick questions or performing tasks. We'll add the Wowser MCP, which lets it do anything in the browser that you can do."
                )
                OnboardingRadioGroup(options: [
                    OnboardingRadioOption(value: .claude, title: "Use Claude", subtitle: "Uses Claude for agent chats and adds the Wowser MCP, so Claude can access the browser."),
                    // TODO: Codex support (agent harness + MCP install).
                    OnboardingRadioOption(value: .codex, title: "Use Codex", subtitle: "Unavailable", disabled: true),
                ], selection: $state.choice)
                if let installError = state.installError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Couldn't add the Wowser MCP", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(installError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("You can copy the install command from Settings › MCP later.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 500, alignment: .leading)
                }
            }
        }, footer: {
            Button(state.installError == nil ? "Continue" : "Continue Anyway", action: connect)
                .keyboardShortcut(.defaultAction)
                .disabled(state.choice == nil || state.installing)
            Button("Skip for now", action: next)
                .buttonStyle(OnboardingButtonStyle(primary: false))
            if state.installing {
                ProgressView().controlSize(.small)
            }
        })
    }

    private func connect() {
        if state.installError != nil {
            next()
            return
        }
        switch state.choice {
        case .claude:
            DefaultsKeys.agentHarness.setString(AgentHarness.claude.rawValue)
            state.installing = true
            let state = $state
            Task {
                let error = await ClaudeMCPInstall.run()
                state.wrappedValue.installing = false
                if let error {
                    state.wrappedValue.installError = error
                } else {
                    // The terminal's "Install in Claude Code" upsell is now moot.
                    DefaultsKeys.hasSeenTerminalUpsell.setBool(true)
                    next()
                }
            }
        case .codex, nil:
            next()
        }
    }
}

// MARK: - Limitations

struct OnboardingLimitationsScreen: View {
    var next: () -> Void

    private let items: [(icon: String, text: String)] = [
        ("flask", "Very experimental"),
        ("person.badge.key", "No passkeys"),
        ("exclamationmark.triangle", "Some sites don't work"),
        ("lock.open", "Not security-tested"),
    ]

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Limitations")
                OnboardingSection {
                    ForEach(items, id: \.text) { item in
                        Label(item.text, systemImage: item.icon)
                            .onboardingCell()
                    }
                }
            }
        }, footer: {
            Button("I understand", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }
}

// MARK: - Goodies

struct OnboardingGoodiesScreen: View {
    var next: () -> Void

    // Defaults match AppDelegate's registered defaults.
    @AppStorage(DefaultsKeys.adblock.rawValue) private var adblock = true
    @AppStorage(DefaultsKeys.autoDarkMode.rawValue) private var autoDarkMode = true

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Enable other goodies", subtitle: "You can change these later in Settings.")
                OnboardingSection {
                    OnboardingBinaryToggleContentCell(title: "Ad blocker", isOn: $adblock)
                    OnboardingBinaryToggleContentCell(title: "Auto dark mode on websites", subtitle: "Darkens sites that don't have a dark mode of their own", isOn: $autoDarkMode)
                    OnboardingMemoryToggleCell()
                }
            }
        }, footer: {
            Button("Continue", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }
}

/// Memory is per data store (see Settings › Memory); this turns it on or off
/// for every visible space's data store at once.
private struct OnboardingMemoryToggleCell: View {
    @ObservedObject private var memory = MemoryStore.shared

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { OnboardingMemoryScopesSnapshot(state: $0) }) { snapshot in
            OnboardingBinaryToggleContentCell(
                title: "Memory",
                subtitle: "Let your AI full-text search your browsing activity",
                isOn: Binding(
                    get: { !snapshot.scopeIDs.isEmpty && snapshot.scopeIDs.allSatisfy(memory.enabledScopesForUI.contains) },
                    set: { on in
                        for id in snapshot.scopeIDs {
                            MemoryStore.shared.setEnabled(on, scope: id)
                        }
                    }
                )
            )
        }
    }
}

private struct OnboardingMemoryScopesSnapshot: Equatable {
    var scopeIDs: Set<UUID>

    init(state: BrowserState) {
        scopeIDs = Set(state.profiles.values.filter { !$0.isHidden }.map(\.dataStoreUUID))
    }
}

// MARK: - Projects

/// Kept in `OnboardingModel` so it survives tab switches.
struct OnboardingProjectsState {
    var added: [ID<Profile>] = []
    /// Suggestion chips already turned into projects.
    var usedSuggestions: Set<String> = []
    var editingCustom = false
    var customTitle = ""
}

struct OnboardingProjectsScreen: View {
    @Binding var state: OnboardingProjectsState
    var next: () -> Void

    @Environment(\.windowID) private var windowID

    static let suggestions = ["Home", "Work", "Taxes", "Hobby", "Travel", "Medical", "Career"]

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Add a few projects", subtitle: "Each project gets its own space, with its own tabs.")
                OnboardingFlowLayout(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { title in
                        OnboardingChip(title: title, systemImage: nil, selected: state.usedSuggestions.contains(title)) {
                            addSuggestion(title)
                        }
                    }
                    OnboardingChip(title: "Coding project", systemImage: "folder", selected: false, action: addFolderProject)
                        .help("Attach a folder: the space gets VS Code, a terminal and a file browser for it.")
                    OnboardingChip(title: "Custom…", systemImage: "pencil", selected: state.editingCustom) {
                        state.editingCustom = true
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                if state.editingCustom {
                    OnboardingSection {
                        OnboardingCustomProjectRow(title: $state.customTitle, add: addCustom)
                    }
                }
                if !state.added.isEmpty {
                    OnboardingSection(title: "Your projects") {
                        ForEach(state.added, id: \.raw) { id in
                            OnboardingProjectRow(profileID: id)
                        }
                    }
                }
            }
        }, footer: {
            Button(state.added.isEmpty ? "Skip" : "Continue", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }

    private func addSuggestion(_ title: String) {
        guard !state.usedSuggestions.contains(title) else { return }
        state.usedSuggestions.insert(title)
        create(title: title, folder: nil)
    }

    private func addCustom() {
        let title = state.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        create(title: title, folder: nil)
        state.customTitle = ""
        state.editingCustom = false
    }

    private func addFolderProject() {
        let state = $state
        let windowID = self.windowID
        FolderPicker.pick(prompt: "Add Project", message: "Choose a folder for the new project") { path in
            Self.create(title: "", folder: path, windowID: windowID, state: state)
        }
    }

    private func create(title: String, folder: String?) {
        Self.create(title: title, folder: folder, windowID: windowID, state: $state)
    }

    private static func create(title: String, folder: String?, windowID: ID<WindowState>?, state: Binding<OnboardingProjectsState>) {
        var id: ID<Profile>?
        BrowserStore.shared.modify { browserState in
            id = browserState.createOnboardingProject(title: title, folderPath: folder, windowID: windowID)
        }
        guard let id else { return }
        state.wrappedValue.added.append(id)
        // Emoji + color theme from the title (AI).
        Task { await BrowserStore.shared.regenerateSpaceTheme(profileID: id) }
    }
}

/// A capsule suggestion button on the projects screen.
private struct OnboardingChip: View {
    var title: String
    var systemImage: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark")
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Lays out subviews left to right, wrapping onto new lines.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private struct OnboardingProjectSnapshot: Equatable {
    var emoji: String?
    var title: String
    var folderPath: String?

    init?(state: BrowserState, profileID: ID<Profile>) {
        guard let profile = state.profiles[profileID] else { return nil }
        emoji = profile.emoji?.nilIfEmpty
        title = profile.displayName
        folderPath = profile.folderPath?.nilIfEmpty
    }
}

private struct OnboardingProjectRow: View {
    var profileID: ID<Profile>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { OnboardingProjectSnapshot(state: $0, profileID: profileID) }) { snapshot in
            if let snapshot {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(SpaceMenu.iconPresets, id: \.self) { emoji in
                            Button(emoji) { setEmoji(emoji) }
                        }
                    } label: {
                        if let emoji = snapshot.emoji {
                            Text(emoji)
                        } else {
                            Image(systemName: "square.dashed")
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    Text(snapshot.title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let folder = snapshot.folderPath {
                        Label((folder as NSString).lastPathComponent, systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Button("Add Folder…") {
                            SpaceMenu.pickFolder(profileID: profileID, currentPath: nil)
                        }
                    }
                }
                .onboardingCell()
            }
        }
    }

    private func setEmoji(_ emoji: String) {
        BrowserStore.shared.modify { state in
            state.profiles[profileID]?.emoji = emoji
        }
    }
}

private struct OnboardingCustomProjectRow: View {
    @Binding var title: String
    var add: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
            TextField("Finding an apartment", text: $title)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onboardingCell()
        .onAppear { focused = true }
    }
}

// MARK: - Tricks

/// Not tracked beyond this flow: the checkboxes are just for the user to
/// tick off. Kept in `OnboardingModel` so they survive tab switches.
struct OnboardingTricksState {
    var optionClick = false
    var askPage = false
    var recentTabs = false
    var dragImage = false
}

struct OnboardingTricksScreen: View {
    @Binding var state: OnboardingTricksState
    var done: () -> Void

    @Environment(\.windowID) private var windowID

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Learn some neat tricks")
                OnboardingSection {
                    OnboardingBinaryToggleContentCell(title: "Option-click a link to open it in a split", isOn: $state.optionClick) {
                        Button("Try it") { openTab(URL(string: "http://example.com")!) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Click in the top bar (⌘L) and ask a question about this page", isOn: $state.askPage) {
                        Button("Try it") { openTab(URL(string: "https://en.wikipedia.org/wiki/Web_browser")!, openCommandBar: true) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Swipe down with three fingers to cycle through recent tabs (or press ⌘E)", subtitle: "Try it!", isOn: $state.recentTabs)
                    OnboardingBinaryToggleContentCell(title: "Drag an image into the sidebar to set it as a space background", subtitle: "Try it with one of these", isOn: $state.dragImage) {
                        HStack(spacing: 6) {
                            ForEach(BuiltinSpaceBackground.all.prefix(3)) { background in
                                DraggableBackgroundThumbnail(background: background)
                            }
                        }
                    }
                }
            }
        }, footer: {
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        })
    }

    private func openTab(_ url: URL, openCommandBar: Bool = false) {
        let windowID = self.windowID
        BrowserStore.shared.modify { state in
            let tab = state.openTab(url: url, windowID: windowID)
            if openCommandBar, let win = windowID ?? state.windowContaining(tabID: tab.id) {
                state.windows[win]?.searchOverlayActive = true
            }
        }
    }
}

private extension BrowserState {
    func windowContaining(tabID: ID<Tab>) -> ID<WindowState>? {
        windows.values.first { $0.tabs.contains(tabID) }?.id
    }
}

/// A bundled background image that drags as image data (not a file URL — the
/// sidebar turns file drops into file tabs, image drops into backgrounds).
struct DraggableBackgroundThumbnail: View {
    var background: BuiltinSpaceBackground
    var width: CGFloat = 48
    var height: CGFloat = 32
    var cornerRadius: CGFloat = 6
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .help(background.title)
        .onDrag { itemProvider() }
        .task(id: background.id) {
            let url = background.resourceURL
            let maxPixels = Int(max(width, height) * 2)
            thumbnail = await Task.detached { url.flatMap { Self.makeThumbnail(url: $0, maxPixels: maxPixels) } }.value
        }
    }

    private func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let url = background.resourceURL
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(url.flatMap { try? Data(contentsOf: $0) }, nil)
            }
            return nil
        }
        return provider
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Claude MCP install

/// Registers the Wowser MCP server with Claude Code (`claude mcp add`), the
/// same command Settings › MCP shows for copying.
enum ClaudeMCPInstall {
    static var serverName: String { isProd() ? "wowser" : "wowserdev" }

    /// Returns nil on success, else a message for the user.
    static func run() async -> String? {
        let url = DefaultsKeys.mcpServerURL.stringValue()
        guard !url.isEmpty else { return "The Wowser MCP server isn't running." }
        let name = serverName
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let claude = ClaudeCodeAgent.discoverClaudeBinary() else {
                return "Couldn't find the claude command. Install Claude Code, then try again."
            }
            // The URL carries an auth key; replace any stale registration.
            _ = runProcess(claude, ["mcp", "remove", "--scope", "user", name])
            let (status, output) = runProcess(claude, ["mcp", "add", "--scope", "user", "--transport", "http", name, url])
            if status == 0 { return nil }
            return output.nilIfEmpty ?? "claude mcp add failed (exit code \(status))."
        }.value
    }

    private static func runProcess(_ path: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    }
}
#endif
