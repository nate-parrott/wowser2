import Foundation

// Onboarding lives in the `NativePageKey.welcome` tab (rendered by
// `WelcomePage` → `OnboardingFlow`). It opens automatically until
// `DefaultsKeys.hasCompletedOnboarding` is set (finishing the flow
// sets it), and can be reopened from the command bar or Settings.

extension BrowserState {
    /// Shows the onboarding tab in `windowID` (or the active window): selects
    /// an existing welcome tab in that window's space, else opens a new one.
    /// Returns the window it was shown in.
    @discardableResult
    public mutating func showOnboarding(windowID: ID<WindowState>? = nil) -> ID<WindowState> {
        let win = windowID.flatMap { windows[$0] } ?? getOrCreateActiveWindow()
        let existing = win.tabs.first { tabID in
            tabs[tabID]?.panes.contains { pane in
                guard let url = pane.info.url, case .welcome = NativePageKey(url: url) else { return false }
                return true
            } ?? false
        }
        if let existing {
            activate(tabId: existing, in: win.id)
        } else {
            openTab(url: NativePageKey.welcome.url, windowID: win.id)
        }
        return win.id
    }

    /// Onboarding's "Make spaces for your projects": a new space titled `title` (and
    /// attached to `folderPath`, if given) that shares logins with the space
    /// the window is showing, so the user doesn't have to log in again.
    public mutating func createOnboardingProject(title: String, folderPath: String?, windowID: ID<WindowState>?) -> ID<Profile> {
        let source = windowID.flatMap { windows[$0]?.profile } ?? activeWindow?.profile
        let id = createNewProfile(sharingLoginsWith: source)
        profiles[id]?.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let folderPath {
            attachFolder(path: folderPath, toProfile: id)
        }
        return id
    }

    /// Whether onboarding's first import should land in `profileID` rather
    /// than a new space: the space is untitled, has no favorites, and has
    /// barely been browsed in.
    func isFreshSpaceForImport(_ profileID: ID<Profile>) -> Bool {
        guard let profile = profiles[profileID] else { return false }
        let favorites = (profile.manualFavorites + profile.autoFavorites).filter { tabs[$0] != nil }
        return profile.title?.nilIfEmpty == nil
            && profile.folderPath?.nilIfEmpty == nil
            && favorites.isEmpty
            && (profile.recentDomains?.count ?? 0) < 5
    }

    /// "Space added" toast for spaces made from onboarding (projects, imports).
    mutating func addSpaceAddedToast(windowID: ID<WindowState>?) {
        guard let windowID = windowID ?? activeWindow?.id else { return }
        addToast(message: "Space added — swipe on the sidebar to view it", icon: "square.stack", in: windowID)
    }

    /// Selects the window's existing empty new tab, else opens one. Onboarding
    /// ends here (its own tab stays open).
    mutating func openOrSelectNewTab(windowID: ID<WindowState>?) {
        let win = windowID.flatMap { windows[$0] } ?? getOrCreateActiveWindow()
        let empty = win.tabs.first { tabID in
            guard let tab = tabs[tabID], tab.panes.count == 1 else { return false }
            return tab.panes.elements.first?.info.url == nil
        }
        if let empty {
            activate(tabId: empty, in: win.id)
        } else {
            let tab = Tab.newTabWithURL(nil)
            insertTab(tab, location: insertionIndex(window: win.id, spawningTabId: win.currentTab), inWindow: win.id)
            activate(tabId: tab.id, in: win.id)
        }
    }
}

extension BrowserStore {
    /// Opens (or selects) the onboarding tab and brings its window forward.
    public func showOnboarding(windowID: ID<WindowState>? = nil) {
        var shownIn: ID<WindowState>?
        modify { shownIn = $0.showOnboarding(windowID: windowID) }
        guard let shownIn else { return }
        NotificationCenter.default.post(name: .bringBrowserWindowToFront, object: nil, userInfo: [bringBrowserWindowToFrontIDKey: shownIn])
    }
}
