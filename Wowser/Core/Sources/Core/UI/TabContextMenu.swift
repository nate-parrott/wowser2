import SwiftUI
import AppKit

// TabContextMenu - reusable context menu for tabs
public struct TabContextMenu: View {
    let tabID: ID<Tab>
    let isFavorite: Bool
    
    public var body: some View {
        WithSnapshot(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { (tab: Tab??) in
            if let tab = tab ?? nil {
                Group {
                    // Copy URL option
                    Button(action: {
                        copyURLToClipboard(url: tab.panes.first?.info.url)
                    }) {
                        Text("Copy URL")
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
    if let urlString = url?.absoluteString {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
    }
}

// Helper function to close a tab
public func closeTab(tabID: ID<Tab>) {
    // First read the state to get the pane ID
    guard let tab = BrowserStore.shared.model.tabs[tabID],
          let paneID = tab.panes.first?.id else { return }
    // Then close via BrowserStore's API
    BrowserStore.shared.close(webContentId: paneID, removeIfPinned: true)
}
