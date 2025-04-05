import SwiftUI

// Favorites grid snapshot to compute the layout
struct FavoritesGridSnapshot: Equatable {
    let rows: [[ID<Tab>]]
    
    init(tabIDs: [ID<Tab>]) {
        let maxItemsPerRow = 4
        var rows = [[ID<Tab>]]()
        var currentRow = [ID<Tab>]()
        
        // Create initial rows with maxItemsPerRow items each
        for tabID in tabIDs {
            currentRow.append(tabID)
            
            if currentRow.count == maxItemsPerRow {
                rows.append(currentRow)
                currentRow = []
            }
        }
        
        // Add any remaining items as the last row
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        
        // Balance the last two rows if the last row has only 1 item
        if rows.count >= 2 && rows.last!.count == 1 && rows[rows.count - 2].count > 1 {
            let lastItem = rows[rows.count - 2].removeLast()
            rows[rows.count - 1].insert(lastItem, at: 0)
        }
        
        self.rows = rows
    }
}

// Favorites tabs section
struct FavoriteTabsView: View {
    let tabIDs: [ID<Tab>]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    @Environment(\.profileID) private var profileID
    
    // Get the grid layout from the snapshot
    private var gridSnapshot: FavoritesGridSnapshot {
        FavoritesGridSnapshot(tabIDs: tabIDs)
    }
    
    var body: some View {
        Group {
            if !tabIDs.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    ForEach(Array(gridSnapshot.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            ForEach(row) { tabID in
                                FavoriteCell(
                                    tabID: tabID,
                                    isSelected: tabID == currentTabID,
                                    windowID: windowID
                                )
                                .frame(height: 40)
                                .sidebarDropTarget { point, bounds in
                                    // Drop before this tab in favorites
                                    guard let profileID = profileID else { return nil }
                                    return .favorites(profile: profileID, before: tabID)
                                }
                            }
                            
//                            // Fill remaining space to ensure even spacing with fewer than max items
//                            if row.count < 4 {
//                                Spacer()
//                                    .frame(maxWidth: .infinity)
//                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                // Add a drop target for the entire area
                .sidebarDropTarget { point, bounds in
                    guard let profileID = profileID else { return nil }
                    return .favorites(profile: profileID, before: nil)
                }
            } else {
                EmptyStateDropTarget(text: "Drag favorites here")
            }
        }
    }
}

// Individual favorite cell that looks up its own data by ID
struct FavoriteCell: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    @State private var isHovered = false
    
    var body: some View {
        // Look up the data from BrowserStore
        WithSnapshot(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { (tab: Tab??) in
            if let tab = tab ?? nil {
                let title = getTabTitle(tab: tab)
                
                FaviconView(url: tab.panes.first?.info.url)
                    .frame(width: 24, height: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
//                    .padding(.horizontal, 12)
                    .background {
                        Capsule()
                            .applyTabStyle(isSelected: isSelected, isHovered: isHovered)
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        selectTab(tabID: tabID, windowID: windowID)
                    }
                    .onHover { hovering in
                        isHovered = hovering
                    }
                    .onDrag {
                        // Create a drag item with the tab ID as text
                        NSItemProvider(object: tabID.raw as NSString)
                    }
                    .help(title)
            }
        }
        .id(tabID)
    }
}

struct EmptyStateDropTarget: View {
    var text: String
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .padding(6)
            .lineLimit(nil)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary)
                    .opacity(0.1)
            }
            .sidebarDropTarget { _, _ in 
                // When dropping in empty favorites section, it's always at the end of manual favorites
                guard let profileID = profileID else { return nil }
                return .favorites(profile: profileID, before: nil)
            }
    }
}

// Helper functions
func selectTab(tabID: ID<Tab>, windowID: ID<WindowState>) {
    BrowserStore.shared.modify { state in 
        state.activate(tabId: tabID, in: windowID)
    }
}

// Helper function to extract tab metadata
func getTabTitle(tab: Tab) -> String {
    return tab.panes.first?.info.title ?? 
           tab.panes.first?.info.url?.host ?? 
           "New Tab"
}
