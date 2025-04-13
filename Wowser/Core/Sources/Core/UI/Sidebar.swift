import SwiftUI
import AppKit
import WebKit

public struct Sidebar: View {
    var floating: Bool
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
        
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
            SidebarContent(snapshot: snapshot, floating: floating)
        }
    }
}

// Helper struct to represent a tab group for the sidebar
private struct TabGroup: Equatable, Identifiable {
    var id: String
    var name: String?
    var tabIDs: [ID<Tab>]
}

// Define a minimal snapshot struct for sidebar data
private struct SidebarSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    
    // List of favorite and regular tab IDs
    let favoriteTabIDs: [ID<Tab>]
    let regularTabGroups: [TabGroup]
    
    // Current tab ID
    let currentTabID: ID<Tab>?
    
    // Downloads
    let hasDownloads: Bool
    
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
        
        // Process tabs in their original order but add headers when group changes
        let regularTabIDs = window?.tabs ?? []
        var tabGroups: [TabGroup] = []
        var currentGroupName: String? = nil
        var currentGroupTabs: [ID<Tab>] = []
        
        // Go through tabs one by one in their original order
        for tabID in regularTabIDs {
            let tabGroupName = tabs[tabID]?.aiTags?.groupName
            
            // If the group changed or this is the first tab
            if tabGroupName != currentGroupName {
                // Save the previous group if it has tabs
                if !currentGroupTabs.isEmpty {
                    tabGroups.append(TabGroup(
                        id: "group-\(currentGroupName ?? "")-\(tabGroups.count)", // Make ID unique with count
                        name: currentGroupName,
                        tabIDs: currentGroupTabs
                    ))
                }
                
                // Start a new group
                currentGroupName = tabGroupName
                currentGroupTabs = [tabID]
            } else {
                // Add to current group
                currentGroupTabs.append(tabID)
            }
        }
        
        // Add the last group if it has tabs
        if !currentGroupTabs.isEmpty {
            let name = currentGroupName ?? "New Tabs"
            tabGroups.append(TabGroup(
                id: "group-\(name)-\(tabGroups.count)",
                name: name,
                tabIDs: currentGroupTabs
            ))
        }
        
        self.regularTabGroups = tabGroups
        
        // Check if there are downloads
        self.hasDownloads = !(window?.downloads.isEmpty ?? true)
    }
}

private struct SidebarContent: View {
    var snapshot: SidebarSnapshot
    var floating: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            if floating {
                Spacer().frame(height: 30)
            }
            
            // Favorite bookmarks/tabs section
            FavoriteTabsView(
                tabIDs: snapshot.favoriteTabIDs,
                currentTabID: snapshot.currentTabID,
                windowID: snapshot.windowID
            )
            .padding(.top, 5)
            .padding(.bottom, 10)
            
//            Divider()
            
            // Regular tabs section with group headers
            GroupedTabsView(
                tabGroups: snapshot.regularTabGroups,
                currentTabID: snapshot.currentTabID,
                windowID: snapshot.windowID
            )
            
            // Downloads section
            if snapshot.hasDownloads {
                DownloadsSidebar(windowID: snapshot.windowID)
            }
            
            Spacer()
            
            // Bottom buttons
            SidebarBottomButtons(windowID: snapshot.windowID)
                .padding(.bottom, 8)
        }
        .frame(width: UIConstants.sidebarWidth)
        .overlay(alignment: .topLeading) {
            topButtons
                .padding(.leading, 72)
        }
    }
    
    @ViewBuilder private var topButtons: some View {
        HStack {
            Button(action: toggleSidebarLocked) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Toggle Sidebar Hidden")
                    .frame(both: 26)
            }
            .buttonStyle(GhostButtonStyle())
        }
        .frame(height: 28)
        .edgesIgnoringSafeArea(.all)
    }
    
    func toggleSidebarLocked() {
        BrowserStore.shared.modify { state in
            state.windows[snapshot.windowID]?.sidebarLocked.toggle()
        }
    }
}

private struct GroupHeader: View {
    var name: String
    
    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Grouped tabs section
private struct GroupedTabsView: View {
    let tabGroups: [TabGroup]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tabGroups) { group in
                    let isFirstGroup = group == tabGroups[0]
                    // Group header
                    if let name = group.name {
                        GroupHeader(name: name)
                    } else if !isFirstGroup {
                        Divider()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 3)
                    }
                    
                    // Tabs in this group
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(group.tabIDs) { tabID in
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
                }
                
                if tabGroups.isEmpty {
                    Color.clear
                }
            }
        }
        // Background drop target for the entire area
        .sidebarDropTarget { point, bounds in
            // Drop at the end of the window's regular tabs
            return .ordinaryTabs(window: windowID, before: nil)
        }
    }
}

// Bottom buttons component
private struct SidebarBottomButtons: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        HStack(spacing: 8) {
            // New Tab button
            Button(action: { newTab() }) {
                Image(systemName: "plus")
                    .imageScale(.large)
                    .help("New Tab")
            }
            
            // Focus button
            Button(action: { focus() }) {
                Image(systemName: "moon")
                    .imageScale(.large)
                    .help("Focus")
            }
        }
        .buttonStyle(BigSidebarButtonStyle())
        .padding(.horizontal, 8)
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
    
    func focus() {
        // No-op for now
        // Will implement focus mode functionality in the future
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
                    // WARNING: onDrag appears to leak the hosting view when clicked
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
            }
        }
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
            .contextMenu {
                TabContextMenu(tabID: tabID, isFavorite: false)
            }
    }
    
    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            // Favicon - use the extracted favicon URL if available
            FaviconView(
                url: tab.panes.first?.info.url,
                faviconURL: tab.panes.first?.info.favicon
            )
            
            // Title with truncation and optional group name
            VStack(alignment: .leading, spacing: 0) {
                Text(getTabTitle(tab: tab))
                    .truncationMode(.tail)
                    .lineLimit(1)
                
//                // Display group name as a subtitle if available
//                if let aiTags = tab.aiTags {
//                    Text(aiTags.groupName)
//                        .font(.system(size: 9, weight: .medium))
//                        .foregroundColor(.secondary)
//                        .truncationMode(.tail)
//                        .lineLimit(1)
//                }
            }
            
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

// Extension to apply tab style to any shape
extension Shape {
    @ViewBuilder
    func applyTabStyle(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            self.fill(
                LinearGradient(colors: [
                    Color("TabBackground", bundle: .module),
                    Color("TabBackground", bundle: .module).opacity(0.7),
                ], startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        } else {
            self.fill(Color.primary.opacity(isHovered ? 0.12 : 0.07))
        }
    }
}

public struct Sidebar_Previews: PreviewProvider {
    public static var previews: some View {
        Sidebar(floating: true)
            .frame(width: 200, height: 500)
            .withBrowserContext(
                windowID: ID<WindowState>(raw: "w0"),
                profileID: .defaultProfile
            )
    }
}
