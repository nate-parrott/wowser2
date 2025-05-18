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

                    // Pick CSS Selector option
                    Button(action: {
                        startPickingSelector(tabID: tabID)
                    }) {
                        Text("Pick CSS Selector")
                    }

                    if isFavorite {
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
public func closeTab(tabID: ID<Tab>) {
    // First read the state to get the pane ID
    guard let tab = BrowserStore.shared.model.tabs[tabID],
          let paneID = tab.panes.first?.id else { return }
    // Then close via BrowserStore's API
    BrowserStore.shared.close(webContentId: paneID, removeIfPinned: true)
}

// Helper function to start CSS selector picker
public func startPickingSelector(tabID: ID<Tab>) {
    // Get the tab data from the store
    let state = BrowserStore.shared.model
    guard let tab = state.tabs[tabID] else { return }

    // Use the focused pane or first pane if none focused
    let focusedPaneIdx = min(tab.focusedPaneIdx, tab.panes.count - 1)
    guard let pane = tab.panes[focusedPaneIdx] else { return }

    // Find which window this tab is in
    guard let window = state.windowContaining(tabId: tabID) else { return }

    // Set the picking selector mode for the window
    BrowserStore.shared.modify { state in
        state.windows[window.id]?.pickingSelectorInPaneId = pane.id
    }
}
