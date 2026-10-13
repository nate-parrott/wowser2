#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Welcome

/// Welcome + pick a theme (the space's background).
struct OnboardingWelcomeScreen: View {
    var next: () -> Void

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Welcome to Wowser")
                        .font(.system(size: 48, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The browser that’ll make you say “wow, the perfect place for all my stuff!”")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Pick a theme to get started")
                    .font(.title3.weight(.semibold))
                OnboardingThemePicker()
            }
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
    var installMCP = true
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
                    subtitle: Text("Ask your agent questions from search, or on any page, using the \(Image.wowie) icon.")
                )
                OnboardingRadioGroup(options: [
                    OnboardingRadioOption(value: .claude, title: "Use Claude", subtitle: "Uses Claude for agent chats."),
                    // TODO: Codex support (agent harness + MCP install).
                    OnboardingRadioOption(value: .codex, title: "Use Codex", subtitle: "Unavailable", disabled: true),
                ], selection: $state.choice)
                if state.choice == .claude {
                    OnboardingSection {
                        OnboardingBinaryToggleContentCell(
                            title: "Install the Wowser MCP in Claude Code",
                            subtitle: "Lets `claude` in any terminal do anything in the browser that you can do. Also lets its read-only browser tools run without asking.",
                            isOn: $state.installMCP
                        )
                    }
                }
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
            guard state.installMCP else { next(); return }
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
    @AppStorage(DefaultsKeys.autoArchiveTabs.rawValue) private var autoArchiveTabs = false

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(title: "Enable other goodies", subtitle: "You can change these later in Settings.")
                OnboardingSection {
                    OnboardingBinaryToggleContentCell(title: "Ad blocker", isOn: $adblock)
                    OnboardingBinaryToggleContentCell(title: "Auto dark mode on websites", subtitle: "Darkens sites that don't have a dark mode of their own", isOn: $autoDarkMode)
                    OnboardingMemoryToggleCell()
                    OnboardingBinaryToggleContentCell(title: "Clean up tabs each night", subtitle: "Moves tabs you haven't used in a while to Old Tabs", isOn: $autoArchiveTabs)
                }
                OnboardingSection(title: "Truly experimental") {
                    OnboardingHTTPSCaptureCell()
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

/// Network capture through the local proxy, plus trusting its certificate so
/// HTTPS is captured too (macOS asks for the user's password). Off again just
/// bypasses the proxy; the certificate stays (Settings › MCP removes it).
private struct OnboardingHTTPSCaptureCell: View {
    @AppStorage(DefaultsKeys.disableNetworkProxy.rawValue) private var proxyDisabled = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        OnboardingBinaryToggleContentCell(
            title: "HTTPS capture",
            subtitle: error ?? "Lets the agent read your API traffic and speak directly to APIs on your behalf. VERY experimental.",
            isOn: Binding(get: { !proxyDisabled }, set: setEnabled)
        ) {
            if working {
                ProgressView().controlSize(.small)
            }
        }
        .disabled(working)
    }

    private func setEnabled(_ on: Bool) {
        error = nil
        proxyDisabled = !on
        guard on else { return }
        working = true
        Task.detached {
            let failure: String? = {
                guard !LocalCA.shared.isRootTrusted(forceRefresh: true) else { return nil }
                do { try LocalCA.shared.installRootAsTrusted() } catch { return "Couldn't trust the certificate: \(error.localizedDescription)" }
                return nil
            }()
            await MainActor.run {
                working = false
                if let failure {
                    error = failure
                    proxyDisabled = true
                }
            }
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
                OnboardingHeader(title: "Make spaces for your projects", subtitle: "Each project gets its own space, with its own tabs.")
                OnboardingFlowLayout(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { title in
                        OnboardingChip(title: title, systemImage: nil, selected: state.usedSuggestions.contains(title)) {
                            addSuggestion(title)
                        }
                    }
                    OnboardingChip(title: "Coding project…", systemImage: "folder", selected: false, action: addFolderProject)
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
                OnboardingSpacesList()
            }
        }, footer: {
            Button("Continue", action: next)
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
        let windowID = self.windowID
        FolderPicker.pick(prompt: "Add Project", message: "Choose a folder for the new project") { path in
            Self.create(title: "", folder: path, windowID: windowID)
        }
    }

    private func create(title: String, folder: String?) {
        Self.create(title: title, folder: folder, windowID: windowID)
    }

    private static func create(title: String, folder: String?, windowID: ID<WindowState>?) {
        var id: ID<Profile>?
        BrowserStore.shared.modify { browserState in
            id = browserState.createOnboardingProject(title: title, folderPath: folder, windowID: windowID)
        }
        guard let id else { return }
        BrowserStore.shared.modify { $0.addSpaceAddedToast(windowID: windowID) }
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

/// "Your projects": every visible space, including ones made before (or
/// outside) this screen.
private struct OnboardingSpacesList: View {
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.visibleProfiles.map(\.id)
        } main: { ids in
            OnboardingSection(title: "Your projects") {
                ForEach(ids, id: \.raw) { id in
                    OnboardingProjectRow(profileID: id)
                }
            }
        }
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
    var chatIcon = false
    var askCommandBar = false
    var customize = false
    var terminal = false
    var vscode = false
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
                    OnboardingBinaryToggleContentCell(title: "Option-click a link to open it in a split", subtitle: "Option-click “Try it”", isOn: $state.optionClick) {
                        Button("Try it", action: tryOptionClick)
                    }
                    OnboardingTrickCell(isOn: $state.chatIcon, title: Text("Click \(Image.wowie) in the toolbar to ask questions about a page")) {
                        Button("Try it") { openTab(Self.wikipediaURL) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Ask the agent a question in the command bar, just like doing a web search", isOn: $state.askCommandBar) {
                        Button("Try it") { perform(.tab) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Ask the agent to customize a page’s appearance or behavior", isOn: $state.customize) {
                        Button("Try it", action: tryCustomize)
                    }
                    OnboardingBinaryToggleContentCell(title: "Use your terminal in the browser", subtitle: "⌘T → New Terminal", isOn: $state.terminal) {
                        Button("Try it") { perform(.terminal) }
                    }
                    OnboardingBinaryToggleContentCell(title: "Use VS Code in the browser", subtitle: "⌘T → New VS Code", isOn: $state.vscode) {
                        Button("Try it") { perform(.vscode) }
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

    private static let exampleURL = URL(string: "https://example.com")!
    private static let wikipediaURL = URL(string: "https://en.wikipedia.org/wiki/Web_browser")!

    private var resolvedWindowID: ID<WindowState>? {
        windowID ?? BrowserStore.shared.model.activeWindow?.id
    }

    private func openTab(_ url: URL) {
        OnboardingLinks.open(url, windowID: windowID)
    }

    private func perform(_ item: NewMenuItem) {
        guard let windowID = resolvedWindowID else { return }
        item.perform(windowID: windowID)
    }

    /// The point is to option-click, so a plain click only explains.
    private func tryOptionClick() {
        guard let windowID = resolvedWindowID else { return }
        if isOpenInSplitViewModifierKeyPressed() {
            BrowserStore.shared.createTab(withURL: Self.exampleURL, in: windowID, activate: true, inCurrentSplit: true)
            state.optionClick = true
        } else {
            BrowserStore.shared.modify { $0.addToast(message: "Hold ⌥ Option while you click “Try it”", icon: "option", in: windowID) }
        }
    }

    private func tryCustomize() {
        guard let windowID = resolvedWindowID else { return }
        openTab(Self.exampleURL)
        AgentChatTabs.askInSplit(query: "Make example.com look super cute (but quickly, this is a demo).", windowID: windowID)
    }
}

/// Like `OnboardingBinaryToggleContentCell`, but with a `Text` title (so it
/// can inline an image).
private struct OnboardingTrickCell<Accessory: View>: View {
    @Binding var isOn: Bool
    var title: Text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) {
                title.padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            accessory
        }
        .onboardingCell()
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

#endif
