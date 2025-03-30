import SwiftUI

public struct Sidebar: View {
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
    
    public init() {}
    
    public var body: some View {
        // Use the snapshot pattern to observe only necessary data
        WithSnapshotMain(store: browserStore) { state in
            // Create a minimal snapshot for sidebar data
            SidebarSnapshot(
                windowID: windowID ?? ID<WindowState>(raw: ""),
                profileID: profileID ?? ID<Profile>(raw: ""),
                windows: state.windows,
                tabs: state.tabs,
                profiles: state.profiles
            )
        } main: { snapshot in
            SidebarContent(snapshot: snapshot)
        }
    }
}

// Define a minimal snapshot struct for sidebar data
private struct SidebarSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    
    // List of favorite and regular tab IDs
    let favoriteTabIDs: [ID<Tab>]
    let regularTabIDs: [ID<Tab>]
    
    // Current tab ID
    let currentTabID: ID<Tab>?
    
    init(windowID: ID<WindowState>, 
         profileID: ID<Profile>,
         windows: [ID<WindowState>: WindowState],
         tabs: [ID<Tab>: Tab],
         profiles: [ID<Profile>: Profile]) {
        
        self.windowID = windowID
        self.profileID = profileID
        
        // Extract window state
        let window = windows[windowID]
        self.currentTabID = window?.currentTab
        
        // Extract favorites
        var favoriteIDs = [ID<Tab>]()
        if let profile = profiles[profileID] {
            favoriteIDs = profile.manualFavorites + profile.autoFavorites
        }
        self.favoriteTabIDs = favoriteIDs
        
        // Extract regular tabs
        self.regularTabIDs = window?.tabs ?? []
    }
}

private struct SidebarContent: View {
    let snapshot: SidebarSnapshot
    
    var body: some View {
        VStack(spacing: 0) {
            // Favorite bookmarks/tabs section
            FavoriteTabsView(
                tabIDs: snapshot.favoriteTabIDs,
                currentTabID: snapshot.currentTabID,
                windowID: snapshot.windowID
            )
            .padding(.vertical, 10)
            
            Divider()
            
            // Research section
            Text("Research")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Regular tabs section
            RegularTabsView(
                tabIDs: snapshot.regularTabIDs,
                currentTabID: snapshot.currentTabID,
                windowID: snapshot.windowID
            )
            
            Spacer()
            
            // New tab button at the bottom
            NewTabButton(windowID: snapshot.windowID)
                .padding(.bottom, 8)
        }
        .frame(width: 200)
        .background {
            TransparentBg()
        }
    }
}

// Favorites tabs section
private struct FavoriteTabsView: View {
    let tabIDs: [ID<Tab>]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tabIDs) { tabID in
                FavoriteTabRow(
                    tabID: tabID,
                    isSelected: tabID == currentTabID,
                    windowID: windowID
                )
                .sidebarDropTarget { point, bounds in
                    // Drop before this tab in favorites
                    guard let profileID = profileID else { return nil }
                    return .favorites(profile: profileID, before: tabID)
                }
            }
        }
        // Add a drop target for the entire area if there are tabs
        .sidebarDropTarget { point, bounds in
            guard let profileID = profileID, !tabIDs.isEmpty else { return nil }
            return .favorites(profile: profileID, before: nil)
        }
        if tabIDs.count == 0 {
            EmptyStateDropTarget(text: "Drag favorites here")
        }
    }
}

private struct EmptyStateDropTarget: View {
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

// Regular tabs section
private struct RegularTabsView: View {
    let tabIDs: [ID<Tab>]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tabIDs) { tabID in
                    RegularTabRow(
                        tabID: tabID,
                        isSelected: tabID == currentTabID,
                        windowID: windowID
                    )
                    .sidebarDropTarget { point, bounds in
                        // Drop before this tab in the window's regular tabs
                        return .ordinaryTabs(window: windowID, before: tabID)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Background drop target for the entire area
            .sidebarDropTarget { point, bounds in
                // Drop at the end of the window's regular tabs
                return .ordinaryTabs(window: windowID, before: nil)
            }
        }
    }
}

// New tab button
private struct NewTabButton: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        Button(action: { newTab() }) {
            HStack {
                Image(systemName: "plus")
                Text("New Tab")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(SidebarButtonStyle())
    }
    
    func newTab() {
        // Create a new tab
        BrowserStore.shared.createTab(
            withURL: nil,  // Start with empty tab
            in: windowID,
            activate: true
        )
        
        // Show search overlay to enter URL
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.searchOverlayActive = true
        }
    }
}

// Individual favorite tab row that looks up its own data by ID
private struct FavoriteTabRow: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    
    var body: some View {
        // Look up the data from BrowserStore
        WithSnapshot(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { (tab: Tab??) in
            if let tab = tab ?? nil {
                FavoriteTabButton(
                    tabID: tabID,
                    tab: tab,
                    isSelected: isSelected,
                    windowID: windowID
                )
                .onDrag {
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
            }
        }
        .id(tabID)
    }
}

// Individual regular tab row that looks up its own data by ID
private struct RegularTabRow: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    @State private var isHovered = false
    
    var body: some View {
        // Look up the data from BrowserStore
        WithSnapshot(store: BrowserStore.shared, snapshot: { $0.tabs[tabID] }) { (tab: Tab??) in
            if let tab = tab ?? nil {
                RegularTabButton(
                    tabID: tabID,
                    tab: tab,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    windowID: windowID
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .onDrag {
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
            }
        }
    }
}

// Favorite tab button component
private struct FavoriteTabButton: View {
    let tabID: ID<Tab>
    let tab: Tab
    let isSelected: Bool
    let windowID: ID<WindowState>
    
    var body: some View {
        HStack(spacing: 8) {
            // Favicon
            FaviconView(url: tab.panes.first?.info.url)
            
            // Title with truncation
            Text(getTabTitle(tab: tab))
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
            selectTab(tabID: tabID, windowID: windowID)
        }))
        .padding(.horizontal, 8)
    }
}

// Regular tab button component
private struct RegularTabButton: View {
    let tabID: ID<Tab>
    let tab: Tab
    let isSelected: Bool
    let isHovered: Bool
    let windowID: ID<WindowState>
    
    var body: some View {
        content
            .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
                selectTab(tabID: tabID, windowID: windowID)
            }))
    }
    
    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            // Favicon
            FaviconView(url: tab.panes.first?.info.url)
            
            // Title with truncation
            VStack(alignment: .leading, spacing: 0) {
                Text(getTabTitle(tab: tab))
                    .truncationMode(.tail)
                
                if isSelected, let host = tab.panes.first?.info.url?.hostWithoutWWW {
                    Text(host)
                        .font(.system(.caption, weight: .medium))
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
            
            Spacer()
            
            // Close button that appears on hover
            if isHovered {
                CloseTabButton(tabID: tabID)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .contentShape(Rectangle())

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

// Helper functions
private func selectTab(tabID: ID<Tab>, windowID: ID<WindowState>) {
    BrowserStore.shared.modify { state in 
        state.activate(tabId: tabID, in: windowID)
    }
}

private func closeTab(tabID: ID<Tab>) {
    // First read the state to get the pane ID
    guard let tab = BrowserStore.shared.model.tabs[tabID],
          let paneID = tab.panes.first?.id else { return }
    // Then close via BrowserStore's API
    BrowserStore.shared.close(webContentId: paneID, removeIfPinned: true)
}

// Helper functions to extract tab metadata

private func getTabTitle(tab: Tab) -> String {
    return tab.panes.first?.info.title ?? 
           tab.panes.first?.info.url?.host ?? 
           "New Tab"
}

public struct Sidebar_Previews: PreviewProvider {
    public static var previews: some View {
        Sidebar()
            .frame(width: 200, height: 500)
            .withBrowserContext(
                windowID: ID<WindowState>(raw: "w0"),
                profileID: ID<Profile>(raw: "p0")
            )
    }
}
