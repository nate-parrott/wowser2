import SwiftUI
import UniformTypeIdentifiers

/// The Space menu: shown when right-clicking a space's paging dot, when
/// right-clicking the sidebar, and when clicking the space icon in the sidebar
/// header. Shows the title, rename, the attached folder, icon and background
/// image submenus, and hide/delete.
struct SpaceMenuItems: View {
    let profileID: ID<Profile>
    let windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            SpaceMenuSnapshot(state: state, profileID: profileID)
        } main: { snapshot in
            SpaceMenuItemsContent(snapshot: snapshot, profileID: profileID, windowID: windowID)
        }
    }
}

private struct SpaceMenuSnapshot: Equatable {
    var title: String
    var emoji: String?
    var folderPath: String?
    var canHide: Bool
    var canDelete: Bool
    var isChatMode: Bool
    var hasBackgroundImage: Bool
    var backgroundMode: SpaceBackgroundMode
    var builtinBackgroundID: String?

    init(state: BrowserState, profileID: ID<Profile>) {
        let profile = state.profiles[profileID]
        title = profile?.title?.nilIfEmpty ?? profile?.autoTitle ?? "Space \((profile?.creationOrder ?? 0) + 1)"
        emoji = profile?.emoji
        folderPath = profile?.folderPath
        canHide = state.canHideProfile(profileID)
        canDelete = state.profiles.count > 1
        isChatMode = state.isChatMode
        hasBackgroundImage = profile?.imageInfo != nil
        backgroundMode = profile?.imageInfo?.effectiveMode ?? .fade
        builtinBackgroundID = profile?.imageInfo?.builtinID
    }

    var displayFolder: String? {
        guard let folderPath else { return nil }
        let home = NSHomeDirectory()
        if folderPath == home { return "~" }
        if folderPath.hasPrefix(home + "/") { return "~" + folderPath.dropFirst(home.count) }
        return folderPath
    }
}

private struct SpaceMenuItemsContent: View {
    let snapshot: SpaceMenuSnapshot
    let profileID: ID<Profile>
    let windowID: ID<WindowState>

    static let iconPresets = ["📓", "💼", "🎮", "🎬", "📚", "✈️", "🏠", "💵", "🔒", "😀", "🧪", "🎨", "🛠️", "🎵", "🛒", "❤️"]

    var body: some View {
        Section {
            Text([snapshot.emoji, snapshot.title].compactMap { $0 }.joined(separator: " "))
            Button("Rename…") { SpaceMenu.rename(profileID: profileID) }
        }

        #if os(macOS)
        Section {
            if let folder = snapshot.displayFolder {
                Text(folder)
                Button("Change Folder…") { SpaceMenu.pickFolder(profileID: profileID, currentPath: snapshot.folderPath) }
                Button("Reveal Folder in Finder") {
                    if let folderPath = snapshot.folderPath {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folderPath)])
                    }
                }
            } else {
                Button("Add Folder…") { SpaceMenu.pickFolder(profileID: profileID, currentPath: nil) }
            }
        }
        #endif

        Section {
            Menu("Icon") {
                ForEach(Self.iconPresets, id: \.self) { emoji in
                    Button(emoji) { setEmoji(emoji) }
                }
                if snapshot.emoji != nil {
                    Divider()
                    Button("Clear Icon") { setEmoji(nil) }
                }
            }
            BackgroundImageMenu(snapshot: snapshot, profileID: profileID)
        }

        Section {
            Toggle("Chat Mode", isOn: Binding(
                get: { snapshot.isChatMode },
                set: { BrowserStore.shared.setChatMode($0) }
            ))
        }

        Section {
            if snapshot.canHide {
                Button("Hide Space") { hide() }
            }
            if snapshot.canDelete {
                Button("Delete Space", role: .destructive) { delete() }
            }
        }
    }

    private func setEmoji(_ emoji: String?) {
        BrowserStore.shared.modify { state in
            state.profiles[profileID]?.emoji = emoji
        }
    }

    private func hide() {
        BrowserStore.shared.modify { state in
            guard state.canHideProfile(profileID) else { return }
            state.hideProfile(profileID)
            state.addToast(message: "Space hidden — restore it in Settings", icon: "eye.slash", in: windowID)
        }
    }

    private func delete() {
        BrowserStore.shared.modify { state in
            state.deleteProfile(profileID)
        }
    }
}

/// Everything about the space's background image in one submenu: built-in
/// images, choosing a file, the rendering mode, and removal.
private struct BackgroundImageMenu: View {
    let snapshot: SpaceMenuSnapshot
    let profileID: ID<Profile>

    var body: some View {
        Menu("Background Image") {
            Section {
                ForEach(BuiltinSpaceBackground.all) { background in
                    Toggle(background.title, isOn: Binding(
                        get: { snapshot.builtinBackgroundID == background.id },
                        set: { _ in BrowserStore.shared.setBuiltinSpaceBackground(background, profileID: profileID) }
                    ))
                }
            }
            #if os(macOS)
            Button("Choose Image…") { SpaceMenu.pickBackgroundImage(profileID: profileID) }
            #endif
            if snapshot.hasBackgroundImage {
                Divider()
                // A Picker inside a menu renders as a submenu with a checkmark
                // on the selected item (Label images don't reliably show in
                // macOS menus).
                Picker("Mode", selection: Binding(
                    get: { snapshot.backgroundMode },
                    set: { BrowserStore.shared.setSpaceBackgroundMode($0, profileID: profileID) }
                )) {
                    ForEach(SpaceBackgroundMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button("Remove Background Image") {
                    BrowserStore.shared.clearSpaceBackgroundImage(profileID: profileID)
                }
            }
        }
    }
}

enum SpaceMenu {
    /// Prompts for a new space title. An empty result clears the user title
    /// so the AI-generated `autoTitle` shows again.
    static func rename(profileID: ID<Profile>) {
        Task { @MainActor in
            let profile = BrowserStore.shared.model.profiles[profileID]
            let current = profile?.title?.nilIfEmpty
            let placeholder = profile?.autoTitle ?? "Space \((profile?.creationOrder ?? 0) + 1)"
            guard let result = await Alerts.showAppPrompt(
                title: "Rename Space",
                message: "",
                textPlaceholder: placeholder,
                submitTitle: "Rename",
                cancelTitle: "Cancel",
                defaultText: current
            ) else { return }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (current ?? "") else { return }
            BrowserStore.shared.modify { state in
                state.profiles[profileID]?.title = trimmed.nilIfEmpty
            }
            // Refresh the space's emoji + gradient theme from the new title.
            await BrowserStore.shared.regenerateSpaceTheme(profileID: profileID)
        }
    }

    #if os(macOS)
    static func pickBackgroundImage(profileID: ID<Profile>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Set Background"
        panel.message = "Choose a background image for this space"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url) else { return }
                BrowserStore.shared.setSpaceBackgroundImage(data: data, profileID: profileID)
            }
        }
    }

    /// Attaches a folder to the space (or swaps the existing one), pinning
    /// VS Code / terminal / files tabs for it.
    static func pickFolder(profileID: ID<Profile>, currentPath: String?) {
        FolderPicker.pick(
            prompt: currentPath == nil ? "Add Folder" : "Change Folder",
            message: "Choose a folder for this space",
            initialPath: currentPath
        ) { path in
            BrowserStore.shared.modify { state in
                state.attachFolder(path: path, toProfile: profileID)
            }
        }
    }
    #endif
}

/// The space's icon in the sidebar header. Clicking it opens the Space menu;
/// the hover backdrop extends a few points beyond the glyph itself.
struct SpaceIconMenuButton: View {
    let profileID: ID<Profile>
    let windowID: ID<WindowState>
    let emoji: String?

    @State private var hovered = false

    var body: some View {
        Menu {
            SpaceMenuItems(profileID: profileID, windowID: windowID)
        } label: {
            Group {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 12))
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.1 : 0))
                    .padding(-3)
            )
            .contentShape(Rectangle().inset(by: -3))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Space options")
    }
}
