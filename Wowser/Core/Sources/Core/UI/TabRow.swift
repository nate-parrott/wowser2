import SwiftUI

// Individual regular tab row that looks up its own data by ID
struct RegularTabRow: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    @State private var isHovered = false
    
    var body: some View {
        // Look up the data from BrowserStore and generate a TabSnapshot
        WithSnapshotMain(store: BrowserStore.shared) { state -> TabSnapshot? in
            if let tab = state.tabs[tabID] {
                return TabSnapshot.from(tab: tab)
            } else {
                return nil
            }
        } main: { snapshot in
            if let snapshot = snapshot {
                RegularTabButton(
                    snapshot: snapshot,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    windowID: windowID
                )
                .help(snapshot.displayName)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .onDrag {
                    // WARNING: onDrag appears to leak the hosting view when clicked
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
            }
        }
    }
}

// TabSnapshot represents the visual appearance data for a tab
struct TabSnapshot: Equatable {
    enum IconType: Equatable {
        case favicon(URL?)
        case sfSymbol(String)
        case empty
    }
    
    var tabID: ID<Tab>
    var displayName: String
    var iconType: IconType
    var url: URL?
    
    // Factory method to create a snapshot from a tab
    static func from(tab: Tab) -> TabSnapshot {
        let snapshot = TabSnapshot(
            tabID: tab.id,
            displayName: getTabTitle(tab: tab),
            iconType: .favicon(tab.panes.first?.info.favicon),
            url: tab.panes.first?.info.url
        )
        
        // Apply various appearance transformations
        return snapshot.preprocessTabAppearance()
    }
    
    // Apply various transformations to customize tab appearance
    private func preprocessTabAppearance() -> TabSnapshot {
        var result = self
        
        // Handle Google search pages
        if let url = self.url, let searchQuery = url.parsedAsGoogleSearchQuery {
            result.displayName = searchQuery
            result.iconType = .sfSymbol("magnifyingglass")
        }
        
        // Handle DuckDuckGo "I'm feeling lucky" pages
        if let url = self.url, url.parsedAsDuckDuckGoLuckyQuery != nil {
            result.displayName = ""
            result.iconType = .empty
        }
        
        if let url, url.hasRootHost("duckduckgo.com"), url.path == "/l" {
            result.iconType = .empty
            result.displayName = ""
        }
        
        if let url, let genKey = GeneratedPageKey(url: url) {
            switch genKey {
            case .homepage:
                result.iconType = .sfSymbol("house")
                result.displayName = "Home"
            case .answer(let q):
                result.iconType = .sfSymbol("message")
                result.displayName = q
            }
        }
//        print("[URL] \(url); icon: \(result.iconType)")
        
        
        // Add more preprocessing rules here
        
        return result
    }
}

// Regular tab button component
private struct RegularTabButton: View {
    let snapshot: TabSnapshot
    let isSelected: Bool
    let isHovered: Bool
    let windowID: ID<WindowState>
    
    var body: some View {
        content
            .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
                selectTab(tabID: snapshot.tabID, windowID: windowID)
            }))
            .contextMenu {
                TabContextMenu(tabID: snapshot.tabID, isFavorite: false)
            }
    }
    
    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            // Icon based on the type in the snapshot
            iconView
            
            // Title with truncation
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.displayName)
                    .truncationMode(.tail)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Close button that appears on hover
            if isHovered {
                CloseTabButton(tabID: snapshot.tabID)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder private var iconView: some View {
        switch snapshot.iconType {
        case .favicon(let faviconURL):
            FaviconView(url: snapshot.url, faviconURL: faviconURL)
            
        case .sfSymbol(let symbolName):
            Image(systemName: symbolName)
                .foregroundColor(.accentColor)
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
            
        case .empty:
            Circle()
                .fill(.primary)
                .opacity(0.1)
                .frame(width: 16, height: 16)
        }
    }
}

private struct CloseTabButton: View {
    var tabID: ID<Tab>
    
    var body: some View {
        Button(action: {
            closeTab(tabID: tabID)
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .help("Close Tab")
                .padding(6)
        }
        .buttonStyle(CircleButtonStyle())
    }
}