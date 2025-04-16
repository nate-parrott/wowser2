import SwiftUI
import AppKit

// Favorites grid snapshot to compute the layout
struct FavoritesGridSnapshot: Equatable {
    enum Cell: Equatable, Identifiable {
        case tab(ID<Tab>)
        case placeholder(String)
        
        var id: String {
            switch self {
            case .tab(let id):
                return id.raw
            case .placeholder(let id):
                return id // UUID().uuidString // Each placeholder gets a unique ID
            }
        }
    }
    
    let rows: [[Cell]]
    
    init(tabIDs: [ID<Tab>]) {
        let maxItemsPerRow = 4
        let minTotalItems = 3 // Minimum number of cells (including placeholders)
        var rows = [[Cell]]()
        var currentRow = [Cell]()
        
        // Create initial rows with real tab items
        for tabID in tabIDs {
            currentRow.append(.tab(tabID))
            
            if currentRow.count == maxItemsPerRow {
                rows.append(currentRow)
                currentRow = []
            }
        }
        
        // Add any remaining items as the last row
        if !currentRow.isEmpty {
            rows.append(currentRow)
            currentRow = []
        }
        
        // Balance the last two rows if the last row has only 1 item
        if rows.count >= 2 && rows.last!.count == 1 && rows[rows.count - 2].count > 1 {
            let lastItem = rows[rows.count - 2].removeLast()
            rows[rows.count - 1].insert(lastItem, at: 0)
        }
        
        // Count total real items
        let totalRealItems = rows.flatMap { $0 }.count
        
        // Add placeholders if needed to reach minimum total
        if totalRealItems < minTotalItems {
            let placeholdersNeeded = minTotalItems - totalRealItems
            
            // Add placeholders to the last row first
            if !rows.isEmpty {
                let lastRowIndex = rows.count - 1
                let spacesInLastRow = maxItemsPerRow - rows[lastRowIndex].count
                let placeholdersForLastRow = min(spacesInLastRow, placeholdersNeeded)
                
                for i in 0..<placeholdersForLastRow {
                    rows[lastRowIndex].append(.placeholder("placeholder:\(i)"))
                }
                
                // If we still need more placeholders, add a new row
                let remainingPlaceholders = placeholdersNeeded - placeholdersForLastRow
                if remainingPlaceholders > 0 {
                    var newRow = [Cell]()
                    for i in 0..<remainingPlaceholders {
                        newRow.append(.placeholder("placeholder:lastrow:\(i)"))
                    }
                    rows.append(newRow)
                }
            } else {
                // No rows yet, create a new row with placeholders
                var newRow = [Cell]()
                for i in 0..<placeholdersNeeded {
                    newRow.append(.placeholder("placeholder:empty:\(i)"))
                }
                rows.append(newRow)
            }
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
        // Always show the grid now, even if tabIDs is empty (will use placeholders)
        VStack(alignment: .center, spacing: 8) {
            ForEach(Array(gridSnapshot.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { cell in
                        switch cell {
                        case .tab(let tabID):
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
                        case .placeholder:
                            PlaceholderFavoriteCell()
                                .frame(height: 40)
//                                .contentShape(Rectangle())
                                .sidebarDropTarget { _, _ in
                                    guard let profileID = profileID else { return nil }
                                    return .favorites(profile: profileID, before: nil)
                                }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
//        // Add a drop target for the entire area
//        .sidebarDropTarget { point, bounds in
//            guard let profileID = profileID else { return nil }
//            return .favorites(profile: profileID, before: nil)
//        }
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
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { tab in
            if let tab = tab ?? nil {
                let title = getTabTitle(tab: tab)
                let pane = tab.panes.first
                
                // Check if reset is available (only when selected and baseInfo URL differs from current URL)
                let canReset = isSelected && 
                    pane?.baseInfo != nil && 
                    pane?.info.url?.historyKey != pane?.baseInfo?.url?.historyKey
                
                FaviconView(
                    url: pane?.baseInfo?.url ?? pane?.info.url,
                    faviconURL: pane?.info.favicon
                )
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .trailing) {
                        if canReset {
                            ResetBadge()
                        }
                    }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .applyTabStyle(isSelected: isSelected, isHovered: isHovered)
                }
                .contentShape(Capsule())
                .onTapGesture {
                    if canReset && isHovered {
                        // Reset to base URL
                        resetTabToBaseURL(tabID: tabID, windowID: windowID)
                    } else {
                        selectTab(tabID: tabID, windowID: windowID)
                    }
                }
                .onHover { hovering in
                    isHovered = hovering
                }
                .onDrag {
                    // WARNING: onDrag appears to leak the hosting view when clicked
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
                .contextMenu {
                    TabContextMenu(tabID: tabID, isFavorite: true)
                }
                .help(canReset && isHovered ? "Reset to original URL" : title)
            }
        }
        .id(tabID)
    }
}

struct PlaceholderFavoriteCell: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Color.clear
////            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
//            .frame(width: 24, height: 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.1 : 0.05))
                Capsule()
                    .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .opacity(colorScheme == .dark ? 0.2 : 0.15)
//                    .fill(Color.primary.opacity(0.05))
            }
            .contentShape(Capsule())
//            .onHover { hovering in
//                isHovered = hovering
//            }
            .help("Drag your favorite tabs here")
    }
    
    private var colors: [Color] {
        if colorScheme == .dark {
            return [Color.black.opacity(0.7), Color.white.opacity(0.4)]
        }
        return [Color.black.opacity(0.5), Color.gray.opacity(0.3)]
    }
}

//struct EmptyStateDropTarget: View {
//    var text: String
//    @Environment(\.profileID) private var profileID
//    
//    var body: some View {
//        Text(text)
//            .multilineTextAlignment(.center)
//            .font(.caption)
//            .padding(6)
//            .foregroundStyle(.secondary)
//            .lineLimit(nil)
//            .frame(maxWidth: .infinity)
//            .frame(height: 40)
//            .background {
//                RoundedRectangle(cornerRadius: 8, style: .continuous)
//                    .fill(Color.primary)
//                    .opacity(0.1)
//            }
//            .sidebarDropTarget { _, _ in 
//                // When dropping in empty favorites section, it's always at the end of manual favorites
//                guard let profileID = profileID else { return nil }
//                return .favorites(profile: profileID, before: nil)
//            }
//    }
//}

// Helper functions
func selectTab(tabID: ID<Tab>, windowID: ID<WindowState>) {
    BrowserStore.shared.modify { state in 
        state.activate(tabId: tabID, in: windowID)
    }
}

// Reset tab to its base URL
func resetTabToBaseURL(tabID: ID<Tab>, windowID: ID<WindowState>) {
    let state = BrowserStore.shared.model
    if let tab = state.tabs[tabID],
       let pane = tab.panes.first,
       let baseURL = pane.baseInfo?.url {
        
        // Navigate to the base URL - this triggers WebContent via BrowserViewController
        if let webContent = BrowserStore.shared.getOrCreateWebContent(forId: pane.id, toBeActiveInWindow: windowID) {
            webContent.load(url: baseURL)
        }
    }
}

// Helper function to extract tab metadata
func getTabTitle(tab: Tab) -> String {
    return tab.panes.first?.info.title?.nilIfEmpty ??
           tab.panes.first?.info.url?.host ??
           "New Tab"
}

private struct ResetBadge: View {
    var body: some View {
        Image(systemName: "arrowshape.turn.up.backward.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary)
            .frame(both: 16)
            .background(Circle().fill(Color("TabBackground", bundle: .module)))
            .frame(both: 1)
    }
}
