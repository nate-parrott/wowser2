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
            Text("One place for all your work")
                .font(.system(size: 48, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .bottomLeading)
        }, footer: {
            Spacer()
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
            if !isDefault {
                Button("Not yet", action: next)
                    .buttonStyle(OnboardingButtonStyle(primary: false))
            }
            Spacer()
            Button(isDefault ? "Continue" : "Set as Default") {
                if !isDefault { DefaultBrowser.makeDefault() }
                next()
            }
            .keyboardShortcut(.defaultAction)
        })
        .task {
            isDefault = await Task.detached { DefaultBrowser.isDefault() }.value
        }
    }
}

// MARK: - AI

private enum OnboardingAIChoice: Hashable {
    case claude
    case codex
}

struct OnboardingAIScreen: View {
    var next: () -> Void

    @State private var choice: OnboardingAIChoice? = .claude
    @State private var installing = false
    @State private var installError: String?

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
                ], selection: $choice)
                if let installError {
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
            Button("Skip for now", action: next)
                .buttonStyle(OnboardingButtonStyle(primary: false))
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
            }
            Button(installError == nil ? "Continue" : "Continue Anyway", action: connect)
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || installing)
        })
    }

    private func connect() {
        if installError != nil {
            next()
            return
        }
        switch choice {
        case .claude:
            DefaultsKeys.agentHarness.setString(AgentHarness.claude.rawValue)
            installing = true
            Task {
                let error = await ClaudeMCPInstall.run()
                installing = false
                if let error {
                    installError = error
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
            Spacer()
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
            Spacer()
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

struct OnboardingProjectsScreen: View {
    var next: () -> Void

    @Environment(\.windowID) private var windowID
    @State private var added: [ID<Profile>] = []
    @State private var draftTitle = ""
    @State private var draftFolder: String?

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Add a few projects", subtitle: "Each project gets its own space, with its own tabs.")
                // TODO: Suggest projects from browsing history with AI.
                OnboardingSection {
                    ForEach(added, id: \.raw) { id in
                        OnboardingProjectRow(profileID: id)
                    }
                    OnboardingNewProjectRow(title: $draftTitle, folder: $draftFolder, add: addDraft)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Add Folder…", action: addFolderProject)
                    Text("Good for coding projects: the space gets VS Code, a terminal and a file browser for the folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }, footer: {
            Spacer()
            Button(added.isEmpty ? "Skip" : "Continue", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }

    private func addDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || draftFolder != nil else { return }
        create(title: title, folder: draftFolder)
        draftTitle = ""
        draftFolder = nil
    }

    private func addFolderProject() {
        FolderPicker.pick(prompt: "Add Project", message: "Choose a folder for the new project") { path in
            create(title: "", folder: path)
        }
    }

    private func create(title: String, folder: String?) {
        var id: ID<Profile>?
        let windowID = self.windowID
        BrowserStore.shared.modify { state in
            id = state.createOnboardingProject(title: title, folderPath: folder, windowID: windowID)
        }
        guard let id else { return }
        added.append(id)
        // Emoji + color theme from the title (AI).
        Task { await BrowserStore.shared.regenerateSpaceTheme(profileID: id) }
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

private struct OnboardingNewProjectRow: View {
    @Binding var title: String
    @Binding var folder: String?
    var add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
            TextField("Finding an apartment", text: $title)
                .textFieldStyle(.plain)
                .onSubmit(add)
            Button {
                FolderPicker.pick(prompt: "Choose", message: "Choose a folder for this project", initialPath: folder) { path in
                    folder = path
                }
            } label: {
                if let folder {
                    Label((folder as NSString).lastPathComponent, systemImage: "folder")
                } else {
                    Label("Folder", systemImage: "plus")
                }
            }
            Button("Add", action: add)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && folder == nil)
        }
        .onboardingCell()
    }
}

// MARK: - Tricks

/// Not tracked: the checkboxes are just for the user to tick off.
struct OnboardingTricksScreen: View {
    var done: () -> Void

    @Environment(\.windowID) private var windowID
    @State private var optionClick = false
    @State private var askPage = false
    @State private var recentTabs = false
    @State private var dragImage = false

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Learn some neat tricks")
                OnboardingSection {
                    OnboardingBinaryToggleContentCell(title: "Option-click a link to open it in a split", isOn: $optionClick) {
                        Button("Try it") { openTab(URL(string: "http://example.com")!) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Click in the top bar (⌘L) and ask a question about this page", isOn: $askPage) {
                        Button("Try it") { openTab(URL(string: "https://en.wikipedia.org/wiki/Web_browser")!, openCommandBar: true) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Swipe down with three fingers to cycle through recent tabs (or press ⌘E)", subtitle: "Try it!", isOn: $recentTabs)
                    OnboardingBinaryToggleContentCell(title: "Drag an image into the sidebar to set it as a space background", subtitle: "Try it with one of these", isOn: $dragImage) {
                        HStack(spacing: 6) {
                            ForEach(BuiltinSpaceBackground.all.prefix(3)) { background in
                                DraggableBackgroundThumbnail(background: background)
                            }
                        }
                    }
                }
            }
        }, footer: {
            Spacer()
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
private struct DraggableBackgroundThumbnail: View {
    var background: BuiltinSpaceBackground
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
        .frame(width: 48, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(background.title)
        .onDrag { itemProvider() }
        .task(id: background.id) {
            let url = background.resourceURL
            thumbnail = await Task.detached { url.flatMap { Self.makeThumbnail(url: $0) } }.value
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

    nonisolated private static func makeThumbnail(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
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
