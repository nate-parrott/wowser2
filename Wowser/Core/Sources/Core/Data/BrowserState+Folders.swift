import Foundation

/// Payload that turns a `Tab` into a sidebar folder: a non-selectable item
/// in the ordinary tab list (so it can sit anywhere) that groups other tabs.
/// The folder tab has no panes. Members keep a saved "pinned" state
/// (`Pane.baseInfo`) like favorites do; closing a member resets it to that
/// state and keeps it in the folder. Members the user has opened since they
/// were last closed are listed under the folder row (see `openTabs`).
public struct TabFolder: Equatable, Codable {
    public var name: String
    /// Every member tab, in folder order.
    public var tabs: [Core.ID<Tab>]
    /// Members currently "open": activated since they were last closed. Shown
    /// as rows under the folder, in the order they were opened. Always a
    /// subset of `tabs`.
    public var openTabs: [Core.ID<Tab>]

    public init(name: String, tabs: [Core.ID<Tab>] = [], openTabs: [Core.ID<Tab>] = []) {
        self.name = name
        self.tabs = tabs
        self.openTabs = openTabs
    }
}

public extension Tab {
    var isFolder: Bool { folder != nil }

    static func newFolderTab(name: String) -> Tab {
        var tab = Tab(id: .assign(), panes: [])
        tab.folder = TabFolder(name: name.nilIfEmpty ?? "Folder")
        return tab
    }
}

public extension BrowserState {
    // MARK: - Lookup

    /// The folder payload of folder tab `id`.
    func folder(id: ID<Tab>) -> TabFolder? {
        tabs[id]?.folder
    }

    /// The folder tab holding `tabId` as a member, if any.
    func folderTab(containingTabId tabId: ID<Tab>) -> Tab? {
        tabs.values.first { $0.folder?.tabs.contains(tabId) == true }
    }

    /// Folder tabs listed in a space, across windows (most recent first).
    func folderTabIDs(inSpace profileId: ID<Profile>) -> [ID<Tab>] {
        var seen = Set<ID<Tab>>()
        var out: [ID<Tab>] = []
        for window in windowsMostRecentFirst {
            for tabID in window.perProfileData[profileId]?.tabs ?? [] where tabs[tabID]?.isFolder == true && !seen.contains(tabID) {
                seen.insert(tabID)
                out.append(tabID)
            }
        }
        return out
    }

    /// Every folder member in a space, in folder order.
    func folderMemberIDs(profileId: ID<Profile>) -> [ID<Tab>] {
        folderTabIDs(inSpace: profileId).flatMap { tabs[$0]?.folder?.tabs ?? [] }
    }

    /// Folder members in a space that are currently open.
    func openFolderMemberIDs(profileId: ID<Profile>) -> [ID<Tab>] {
        folderTabIDs(inSpace: profileId).flatMap { tabs[$0]?.folder?.openTabs ?? [] }
    }

    // MARK: - Mutation

    mutating func modifyFolder(id: ID<Tab>, _ block: (inout TabFolder) -> Void) {
        guard tabs[id]?.folder != nil else { return }
        modifyTab(id: id) { tab in
            if var folder = tab.folder {
                block(&folder)
                tab.folder = folder
            }
        }
    }

    /// Creates an empty folder at the end of a space's tab list in `window`
    /// (the window's current space unless `profileId` is given).
    @discardableResult
    mutating func createFolder(name: String, windowID: ID<WindowState>, profileId: ID<Profile>? = nil) -> ID<Tab>? {
        guard let win = windows[windowID] else { return nil }
        let profile = profileId ?? win.profile
        let tab = Tab.newFolderTab(name: name)
        _registerTab_unsafe(tab)
        if windows[windowID]!.perProfileData[profile] == nil {
            windows[windowID]!.perProfileData[profile] = .init(tabs: [])
        }
        windows[windowID]!.perProfileData[profile]!.tabs.append(tab.id)
        return tab.id
    }

    mutating func renameFolder(id: ID<Tab>, name: String) {
        modifyFolder(id: id) { $0.name = name.nilIfEmpty ?? $0.name }
    }

    /// Removes a folder. Its members are moved to the ordinary tab list of
    /// `window` (right after where the folder was), or removed outright when
    /// it's nil.
    mutating func deleteFolder(id: ID<Tab>, moveTabsToWindow window: ID<WindowState>?) {
        guard let folder = folder(id: id) else { return }
        if let window, windows[window] != nil {
            // Insert members where the folder sat, in order.
            let followingTab = windows[window]?.tabs.firstIndex(of: id).flatMap { windows[window]?.tabs.get($0 + 1) }
            for tabID in folder.tabs {
                move(tab: tabID, to: .ordinaryTabs(window: window, before: followingTab), makeActiveInWindow: nil)
            }
        }
        // Any remaining members go with the folder.
        _removeTab_unsafe_doesntCloseWebContent(tabId: id)
    }

    /// Puts an existing tab into a folder (pinning its current state). Pass
    /// `open` to also list it under the folder row right away.
    mutating func addTab(_ tabId: ID<Tab>, toFolder folderId: ID<Tab>, before: ID<Tab>? = nil, open: Bool = false) {
        let dest = TabDropDestination.folder(folderTab: folderId, before: before, open: open)
        guard canMove(tab: tabId, to: dest) else { return }
        move(tab: tabId, to: dest, makeActiveInWindow: nil)
    }

    /// Drops a tab from its folder and removes the tab itself.
    mutating func removeTabFromFolder(_ tabId: ID<Tab>) {
        guard folderTab(containingTabId: tabId) != nil else { return }
        _removeTab_unsafe_doesntCloseWebContent(tabId: tabId)
    }

    /// Called on activation: a folder member the user opens joins the folder's
    /// open list (once). No-op for non-members.
    mutating func markFolderTabOpen(_ tabId: ID<Tab>) {
        guard let folderTab = folderTab(containingTabId: tabId), folderTab.folder?.openTabs.contains(tabId) == false else { return }
        modifyFolder(id: folderTab.id) { $0.openTabs.append(tabId) }
    }

    /// Closing a folder member: reset it to its pinned state and take it off
    /// the folder's open list. The tab stays in the folder.
    mutating func resetFolderTab(_ tabId: ID<Tab>) {
        guard let folderTab = folderTab(containingTabId: tabId) else { return }
        modifyTab(id: tabId) { tab in
            for i in tab.panes.asArray.indices {
                if let base = tab.panes[i]?.baseInfo {
                    tab.panes[i]?.info = base
                }
            }
        }
        modifyFolder(id: folderTab.id) { $0.openTabs.removeAll { $0 == tabId } }
    }

    /// Detaches `tabId` from whatever folder holds it, without touching the
    /// tab itself. Used by moves and removal.
    mutating func _detachFromFolder(_ tabId: ID<Tab>) {
        guard let folderTab = folderTab(containingTabId: tabId) else { return }
        modifyFolder(id: folderTab.id) {
            $0.tabs.removeAll { $0 == tabId }
            $0.openTabs.removeAll { $0 == tabId }
        }
    }
}

extension BrowserStore {
    /// "Put away" a folder: close every open member, which resets each to its
    /// pinned state and collapses the folder back to a single row.
    func putAwayFolder(id: ID<Tab>) {
        assertOnMainThread()
        let state = model
        guard let folder = state.folder(id: id) else { return }
        for tabID in folder.openTabs {
            for paneID in state.tabs[tabID]?.panes.map(\.id) ?? [] {
                close(webContentId: paneID, removeIfPinned: false)
            }
        }
    }
}
