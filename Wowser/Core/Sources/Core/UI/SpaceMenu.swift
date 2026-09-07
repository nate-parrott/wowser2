import SwiftUI

/// The Space menu: shown when right-clicking a space's paging dot and when
/// clicking the space icon in the sidebar header. Shows the title (edit it via
/// the header), the attached folder, an icon submenu, and hide/delete.
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

    init(state: BrowserState, profileID: ID<Profile>) {
        let profile = state.profiles[profileID]
        title = profile?.title?.nilIfEmpty ?? profile?.autoTitle ?? "Space \((profile?.creationOrder ?? 0) + 1)"
        emoji = profile?.emoji
        folderPath = profile?.folderPath
        canHide = state.canHideProfile(profileID)
        canDelete = state.profiles.count > 1
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

enum SpaceMenu {
    #if os(macOS)
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
                        .font(.system(size: 13))
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
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
