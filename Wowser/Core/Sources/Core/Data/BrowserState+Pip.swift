import Foundation

// MARK: - Picture-in-picture tabs

public extension BrowserState {
    /// Turns pip mode on or off for a tab. Split tabs can't be pipped.
    /// Enabling deselects the tab from any window showing it (pip tabs never
    /// show in main content) and opens the floating panel immediately.
    mutating func setPipMode(_ on: Bool, tabId: ID<Tab>) {
        guard let tab = tabs[tabId], tab.isPip != on else { return }
        if on {
            guard !tab.isSplit else { return }
            // Deselect from any window currently showing this tab
            for (windowID, window) in windows where window.currentTab == tabId {
                let next = tabToSelectAfterClosing(tabId: tabId)
                activate(tabId: next == tabId ? nil : next, in: windowID)
            }
            modifyTab(id: tabId) { tab in
                tab.pipMode = true
                tab.pipOpen = true
            }
        } else {
            modifyTab(id: tabId) { tab in
                tab.pipMode = nil
                tab.pipOpen = nil
            }
        }
    }

    /// Shows/hides the floating panel for a pip tab (clicking the tab row).
    mutating func togglePipOpen(tabId: ID<Tab>) {
        guard let tab = tabs[tabId], tab.isPip else { return }
        setPipOpen(tab.pipOpen != true, tabId: tabId)
    }

    mutating func setPipOpen(_ open: Bool, tabId: ID<Tab>) {
        guard let tab = tabs[tabId], tab.isPip else { return }
        modifyTab(id: tabId) { $0.pipOpen = open ? true : nil }
    }

    /// Descriptors for every pip panel that should currently be on screen.
    var openPips: [PipDescriptor] {
        tabs.values
            .filter { $0.isPip && $0.pipOpen == true }
            .compactMap { tab -> PipDescriptor? in
                guard let pane = tab.panes.first else { return nil }
                // Host window: used for webcontent creation + expand target.
                let windowID: ID<WindowState>?
                if let last = tab.lastActiveInWindow, windows[last] != nil {
                    windowID = last
                } else {
                    windowID = windows.keys.first
                }
                guard let windowID, let window = windows[windowID] else { return nil }
                return PipDescriptor(
                    tabID: tab.id,
                    paneID: pane.id,
                    windowID: windowID,
                    profileID: window.profile
                )
            }
            .sorted(by: { $0.tabID.raw < $1.tabID.raw })
    }
}

public struct PipDescriptor: Equatable, Identifiable {
    public var tabID: ID<Tab>
    public var paneID: ID<WebContent>
    public var windowID: ID<WindowState>
    public var profileID: ID<Profile>

    public var id: ID<Tab> { tabID }
}
