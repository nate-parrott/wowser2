import SwiftUI

/// What the sidebar needs to draw one folder (see `TabFolder`).
struct FolderSnapshot: Equatable, Identifiable {
    /// The folder tab's id.
    var id: Core.ID<Tab>
    var name: String
    var tabIDs: [Core.ID<Tab>]
    var openTabIDs: [Core.ID<Tab>]

    init?(folderTab: Tab, tabs: [Core.ID<Tab>: Tab]) {
        guard let folder = folderTab.folder else { return nil }
        id = folderTab.id
        name = folder.name
        tabIDs = folder.tabs.filter { tabs[$0] != nil }
        openTabIDs = folder.openTabs.filter { tabs[$0] != nil }
    }
}

/// A folder row plus the rows for its open members, boxed together when there
/// are any. Dropping a tab on the folder row adds it to the folder; dropping
/// it among the open rows adds it and opens it.
struct FolderSection: View {
    let folder: FolderSnapshot
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderRow(folder: folder, windowID: windowID)
                .sidebarDropTarget { _, _ in
                    .folder(folderTab: folder.id, before: nil, open: false)
                }
            ForEach(folder.openTabIDs, id: \.raw) { tabID in
                RegularTabRow(
                    tabID: tabID,
                    isSelected: tabID == currentTabID,
                    windowID: windowID
                )
                .sidebarDropTarget { _, _ in
                    .folder(folderTab: folder.id, before: tabID, open: true)
                }
            }
        }
        .background {
            // Hugs the rows' hover/selection footprint exactly (see the
            // insets in TabStyleButtonModifier), no extra spread.
            if !folder.openTabIDs.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
        }
    }
}

/// The folder's own row: icon, name, member count. Hovering shows the member
/// list in a popover off the trailing edge; the popover stays while the
/// pointer is inside it.
private struct FolderRow: View {
    let folder: FolderSnapshot
    let windowID: ID<WindowState>

    @State private var isHovered = false
    @State private var previewHovered = false
    @State private var showPreview = false
    @State private var pendingHoverChange: DispatchWorkItem?
    @State private var lastClickAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: .sfSymbol("folder"))
            Text(folder.name)
                .truncationMode(.tail)
                .lineLimit(1)
            Spacer()
            if isHovered, !folder.openTabIDs.isEmpty {
                Button(action: { BrowserStore.shared.putAwayFolder(id: folder.id) }) {
                    Image(systemName: "tray.and.arrow.down")
                        .help("Put Away Open Tabs")
                }
                .buttonStyle(TabAccessoryButtonStyle())
            } else if !folder.tabIDs.isEmpty {
                Text("\(folder.tabIDs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, isMobile() ? 14 : 8)
        .padding(.trailing, 4)
        .frame(height: isMobile() ? 44 : UIConstants.macTabHeight)
        .contentShape(Rectangle())
        .modifier(TabStyleButtonModifier(isSelected: false, pressed: {
            // Double-click renames; single click shows the preview (and
            // keeps it up if it's already showing).
            let now = Date()
            if let last = lastClickAt, now.timeIntervalSince(last) < 0.5 {
                lastClickAt = nil
                renameFolder(folderID: folder.id)
            } else {
                lastClickAt = now
                pendingHoverChange?.cancel()
                showPreview = true
            }
        }))
        .onHover { hovering in
            isHovered = hovering
            scheduleHoverChange()
        }
        .onDrag {
            // The folder is a tab-strip item: drag it to reorder
            NSItemProvider.tabDrag(tabID: folder.id, fileURL: nil)
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            FolderPreview(folderID: folder.id, windowID: windowID, onSelect: { showPreview = false })
                .onHover { hovering in
                    previewHovered = hovering
                    scheduleHoverChange()
                }
        }
        .contextMenu {
            Button("Rename Folder…") { renameFolder(folderID: folder.id) }
            if !folder.openTabIDs.isEmpty {
                Button("Put Away Open Tabs") { BrowserStore.shared.putAwayFolder(id: folder.id) }
            }
            Button("Delete Folder") {
                BrowserStore.shared.modify { state in
                    state.deleteFolder(id: folder.id, moveTabsToWindow: windowID)
                }
            }
        }
        .help(folder.tabIDs.isEmpty ? "Drag tabs here to add them to this folder" : folder.name)
    }

    /// Show after a short dwell on the row; hide a moment after the pointer
    /// leaves both the row and the popover (so it can cross the gap between them).
    private func scheduleHoverChange() {
        pendingHoverChange?.cancel()
        let wantShown = isHovered || previewHovered
        guard wantShown != showPreview else { return }
        let work = DispatchWorkItem {
            if (isHovered || previewHovered) == wantShown, showPreview != wantShown {
                showPreview = wantShown
            }
        }
        pendingHoverChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wantShown ? 0.3 : 0.4), execute: work)
    }
}

/// Member list shown beside a folder row. Clicking a member opens it (it
/// joins the folder's open rows); the hover "x" removes it from the folder.
private struct FolderPreview: View {
    let folderID: ID<Tab>
    let windowID: ID<WindowState>
    var onSelect: () -> Void

    private struct Snapshot: Equatable {
        var name: String
        var tabIDs: [ID<Tab>]
        var openTabIDs: [ID<Tab>]
        var currentTabID: ID<Tab>?
    }

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state -> Snapshot? in
            guard let folder = state.folder(id: folderID) else { return nil }
            return Snapshot(
                name: folder.name,
                tabIDs: folder.tabs.filter { state.tabs[$0] != nil },
                openTabIDs: folder.openTabs,
                currentTabID: state.windows[windowID]?.currentTab
            )
        } main: { snapshot in
            if let snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    if snapshot.tabIDs.isEmpty {
                        Text("Drag tabs here to add them to “\(snapshot.name)”")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                            .padding(12)
                    } else {
                        ForEach(snapshot.tabIDs, id: \.raw) { tabID in
                            FolderPreviewRow(
                                tabID: tabID,
                                isOpen: snapshot.openTabIDs.contains(tabID),
                                isSelected: snapshot.currentTabID == tabID,
                                windowID: windowID,
                                onSelect: onSelect
                            )
                        }
                    }
                }
                .padding(4)
                .frame(width: 240)
            }
        }
    }
}

private struct FolderPreviewRow: View {
    let tabID: ID<Tab>
    let isOpen: Bool
    let isSelected: Bool
    let windowID: ID<WindowState>
    var onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state -> TabSnapshot? in
            state.tabs[tabID].map(TabSnapshot.from(tab:))
        } main: { snapshot in
            if let snapshot {
                HStack(spacing: 8) {
                    TabIconView(icon: snapshot.appearance.icon)
                    Text(snapshot.appearance.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(isOpen ? 1 : 0.7)
                    Spacer()
                    if isHovered {
                        Button(action: {
                            BrowserStore.shared.modify { $0.removeTabFromFolder(tabID) }
                        }) {
                            Image(systemName: "xmark")
                                .help("Remove from Folder")
                        }
                        .buttonStyle(TabAccessoryButtonStyle())
                    } else if isOpen {
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(both: 5)
                            .padding(.trailing, 8)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: UIConstants.macTabHeight)
                .contentShape(Rectangle())
                .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
                    didClickTabToSelect(tabID: tabID, windowID: windowID)
                    onSelect()
                }))
                .onHover { isHovered = $0 }
                .onDrag {
                    NSItemProvider.tabDrag(tabID: tabID, fileURL: snapshot.fileURL)
                }
                .contextMenu {
                    TabContextMenu(tabID: tabID, isFavorite: false)
                }
                .help(snapshot.appearance.title)
            }
        }
    }
}

// MARK: - Actions

/// Prompts for a name and creates a folder in the window's current space.
public func newFolder(windowID: ID<WindowState>) {
    Task { @MainActor in
        let result = await Alerts.showAppPrompt(
            title: "New Folder",
            message: "Folders group tabs into one sidebar item. Drag tabs onto the folder to add them.",
            textPlaceholder: "Folder name",
            submitTitle: "Create",
            cancelTitle: "Cancel",
            defaultText: ""
        )
        guard let result else { return }
        BrowserStore.shared.modify { state in
            state.createFolder(name: result, windowID: windowID)
        }
    }
}

public func renameFolder(folderID: ID<Tab>) {
    Task { @MainActor in
        let current = BrowserStore.shared.model.folder(id: folderID)?.name ?? ""
        let result = await Alerts.showAppPrompt(
            title: "Rename Folder",
            message: "Enter a name for this folder.",
            textPlaceholder: "Folder name",
            submitTitle: "Rename",
            cancelTitle: "Cancel",
            defaultText: current
        )
        guard let result else { return }
        BrowserStore.shared.modify { state in
            state.renameFolder(id: folderID, name: result)
        }
    }
}
