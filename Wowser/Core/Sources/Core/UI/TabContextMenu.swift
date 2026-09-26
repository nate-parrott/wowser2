import SwiftUI

// TabContextMenu - reusable context menu for tabs
public struct TabContextMenu: View {
    let tabID: ID<Tab>
    let isFavorite: Bool
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { (tab: Tab?) in
            if let tab {
                Group {
                    // Copy URL option
                    Button(action: {
                        copyURLToClipboard(url: tab.panes.first?.info.url)
                    }) {
                        Text("Copy Link")
                    }

                    if tab.panes.count > 1 {
                        Button(action: {
                            BrowserStore.shared.modify { state in
                                state.separateSplitTabs(tabId: tabID)
                            }
                        }) {
                            Text("Separate Split Tabs")
                        }
                    }

                    Button(action: {
                        renameTab(tabID: tabID)
                    }) {
                        Text("Rename")
                    }

                    if tab.customTitle?.nilIfEmpty != nil {
                        Button(action: {
                            BrowserStore.shared.modify { state in
                                state.modifyTab(id: tabID) { $0.customTitle = nil }
                            }
                        }) {
                            Text("Clear Custom Title")
                        }
                    }

                    Button(action: {
                        setTabEmoji(tabID: tabID)
                    }) {
                        Text("Set Icon…")
                    }

                    if tab.customEmoji?.nilIfEmpty != nil {
                        Button(action: {
                            BrowserStore.shared.modify { state in
                                state.modifyTab(id: tabID) { $0.customEmoji = nil }
                            }
                        }) {
                            Text("Clear Icon")
                        }
                    }

                    if !tab.isSplit || tab.isPip {
                        Button(action: {
                            BrowserStore.shared.modify { state in
                                state.setPipMode(!tab.isPip, tabId: tabID)
                            }
                        }) {
                            Text(tab.isPip ? "Turn Off Picture in Picture" : "Open as Picture in Picture")
                        }
                    }

                    #if os(macOS)
                    FileTabMenuItems(tab: tab)
                    #endif

                    MoveToSpaceMenu(tabID: tabID)
                    FolderMenuItems(tabID: tabID)

                    if isFavorite {
                        if let pane = tab.panes.first,
                           pane.baseInfo != nil,
                           pane.info.url?.historyKey != pane.baseInfo?.url?.historyKey {
                            Button(action: {
                                updatePinnedURL(tabID: tabID)
                            }) {
                                Text("Update Pinned URL")
                            }
                        }

                        // Remove from favorites option
                        Button(action: {
                            removeFromFavorites(tabID: tabID)
                        }) {
                            Text("Remove from Favorites")
                        }
                    } else {
                        // Close tab option
                        Button(action: {
                            closeTab(tabID: tabID)
                        }) {
                            Text("Close Tab")
                        }
                    }

                    Menu("Advanced") {
                        Button(action: {
                            BrowserStore.shared.modify { $0.startSelectorPicker(tabID: tabID, mode: .normal) }
                        }) {
                            Text("Pick CSS Selector")
                        }
                        Button(action: {
                            BrowserStore.shared.modify { $0.startSelectorPicker(tabID: tabID, mode: .augmented) }
                        }) {
                            Text("Pick Augmented Selector")
                        }
                    }
                }
            }
        }
    }
}

// Helper function to remove a tab from favorites
public func removeFromFavorites(tabID: ID<Tab>) {
    // Get the profile ID and update manual favorites
    BrowserStore.shared.modify { state in
        for (profileID, profile) in state.profiles {
            if profile.manualFavorites.contains(tabID) {
                state.profiles[profileID]?.manualFavorites.removeAll { $0 == tabID }
                break
            } else if profile.autoFavorites.contains(tabID) {
                state.profiles[profileID]?.autoFavorites.removeAll { $0 == tabID }
                break
            }
        }
    }
}

// Re-pin a favorite to its current URL: replace the pane's baseInfo with its
// current info so "reset" now returns here.
public func updatePinnedURL(tabID: ID<Tab>) {
    BrowserStore.shared.modify { state in
        state.modifyTab(id: tabID) { tab in
            if let pane = tab.panes.first, pane.baseInfo != nil {
                tab.panes[0]!.baseInfo = pane.info
            }
        }
    }
}

// Copy URL to clipboard
public func copyURLToClipboard(url: URL?) {
    guard let urlString = url?.absoluteString else { return }
    
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(urlString, forType: .string)
    #else
    UIPasteboard.general.string = urlString
    #endif
}

// Helper function to close a tab
#if os(macOS)
/// Open / Reveal in Finder / Delete for file tabs, plus Cancel Download while
/// a download is still running.
private struct FileTabMenuItems: View {
    var tab: Tab

    var body: some View {
        if let fileURL = tab.draggableFileURL {
            let download = tab.panes.first?.download
            let inProgress = download?.status == .inProgress
            Divider()
            if inProgress, let paneID = tab.panes.first?.id {
                Button("Cancel Download") {
                    DownloadManager.shared.cancelDownload(paneID: paneID)
                }
            }
            if let openable = tab.openableFileURL {
                Button("Open") { NSWorkspace.shared.open(openable) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            if !inProgress {
                Button(download == nil ? "Delete" : "Delete File", role: .destructive) {
                    try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                    closeTab(tabID: tab.id)
                }
            }
            Divider()
        }
    }
}
#endif

public func closeTab(tabID: ID<Tab>) {
    // First read the state to get the pane ID
    let state = BrowserStore.shared.model
    guard let tab = state.tabs[tabID],
          let paneID = tab.panes.first?.id else { return }
    // Closing a folder member resets it to its pinned state and keeps it in
    // the folder ("Remove from Folder" is the way to actually drop it).
    let inFolder = state.folderTab(containingTabId: tabID) != nil
    BrowserStore.shared.close(webContentId: paneID, removeIfPinned: !inFolder)
}

// Helper function to rename a tab via a prompt
public func renameTab(tabID: ID<Tab>) {
    Task { @MainActor in
        let current = BrowserStore.shared.model.tabs[tabID]
        let defaultText = current?.customTitle?.nilIfEmpty ?? current?.appearance().title ?? ""
        let result = await Alerts.showAppPrompt(
            title: "Rename Tab",
            message: "Enter a custom title for this tab.",
            textPlaceholder: "Tab title",
            submitTitle: "Rename",
            cancelTitle: "Cancel",
            defaultText: defaultText
        )
        guard let result else { return }
        BrowserStore.shared.modify { state in
            state.modifyTab(id: tabID) { $0.customTitle = result.nilIfEmpty }
        }
    }
}

// Helper function to set a tab's emoji icon via a prompt. Empty input clears it.
public func setTabEmoji(tabID: ID<Tab>) {
    Task { @MainActor in
        let defaultText = BrowserStore.shared.model.tabs[tabID]?.customEmoji?.nilIfEmpty ?? ""
        let result = await Alerts.showAppPrompt(
            title: "Set Tab Icon",
            message: "Enter an emoji to use as this tab's icon. Leave empty to use the site's favicon.",
            textPlaceholder: "Emoji",
            submitTitle: "Set Icon",
            cancelTitle: "Cancel",
            defaultText: defaultText
        )
        guard let result else { return }
        BrowserStore.shared.modify { state in
            state.modifyTab(id: tabID) { $0.customEmoji = result.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        }
    }
}

/// "Add to Folder" submenu for tabs outside a folder; "Remove from Folder"
/// for members. Folders come from the space the tab is in.
private struct FolderMenuItems: View {
    let tabID: ID<Tab>

    private struct Snapshot: Equatable {
        struct Folder: Equatable, Identifiable {
            var id: ID<Tab>
            var name: String
        }
        var isFolder: Bool
        var inFolder: Bool
        var folders: [Folder]
    }

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            let window = state.windowContaining(tabId: tabID)
            let profileID = window.flatMap { state.space(containingTabId: tabID, inWindow: $0.id) } ?? window?.profile
            return Snapshot(
                isFolder: state.tabs[tabID]?.isFolder == true,
                inFolder: state.folderTab(containingTabId: tabID) != nil,
                folders: profileID.map { state.folderTabIDs(inSpace: $0) }?
                    .filter { $0 != tabID }
                    .compactMap { id in state.folder(id: id).map { .init(id: id, name: $0.name) } } ?? []
            )
        } main: { snapshot in
            if snapshot.isFolder {
                EmptyView()
            } else if snapshot.inFolder {
                Button("Remove from Folder") {
                    BrowserStore.shared.modify { $0.removeTabFromFolder(tabID) }
                }
            } else if !snapshot.folders.isEmpty {
                Menu("Add to Folder") {
                    ForEach(snapshot.folders) { folder in
                        Button(folder.name) {
                            BrowserStore.shared.modify { $0.addTab(tabID, toFolder: folder.id, open: true) }
                        }
                    }
                }
            }
        }
    }
}

/// "Move to Space" submenu: every visible space except the one the tab is in.
private struct MoveToSpaceMenu: View {
    let tabID: ID<Tab>

    private struct Snapshot: Equatable {
        struct Space: Equatable, Identifiable {
            var id: ID<Profile>
            var name: String
        }
        var windowID: ID<WindowState>?
        var spaces: [Space]
    }

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            let window = state.windowContaining(tabId: tabID)
            let current = window.flatMap { state.space(containingTabId: tabID, inWindow: $0.id) } ?? window?.profile
            return Snapshot(
                windowID: window?.id,
                spaces: state.visibleProfiles
                    .filter { $0.id != current }
                    .map { .init(id: $0.id, name: $0.displayName) }
            )
        } main: { snapshot in
            if let windowID = snapshot.windowID, !snapshot.spaces.isEmpty {
                Menu("Move to Space") {
                    ForEach(snapshot.spaces) { space in
                        Button(space.name) {
                            BrowserStore.shared.move(tab: tabID, toSpace: space.id, inWindow: windowID)
                        }
                    }
                }
            }
        }
    }
}
