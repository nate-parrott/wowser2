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
                profileID: nil, // Use window's current profile
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
         profileID: ID<Profile>?, // Can be nil, will use window's current profile
         windows: [ID<WindowState>: WindowState],
         tabs: [ID<Tab>: Tab],
         profiles: [ID<Profile>: Profile]) {
        
        self.windowID = windowID
        
        // Use provided profileID if not nil, otherwise use window's current profile
        let window = windows[windowID]
        let effectiveProfileID = profileID ?? window?.profile ?? .defaultProfile
        self.profileID = effectiveProfileID
        
        // Get per-profile data from window state
        let perProfileData = window?.perProfileData[effectiveProfileID]
        
        // Get profile-specific current tab
        self.currentTabID = perProfileData?.currentTab
        
        // Extract favorites
        var favoriteIDs = [ID<Tab>]()
        if let profile = profiles[effectiveProfileID] {
            favoriteIDs = profile.manualFavorites + profile.autoFavorites
        }
        self.favoriteTabIDs = favoriteIDs
        
        // Process tabs in their original order but add headers when group changes
        let regularTabIDs = perProfileData?.tabs ?? []
        var tabGroups: [TabGroup] = []
        var currentGroupName: String? = nil
        var currentGroupTabs: [ID<Tab>] = []
        
        if regularTabIDs.count < UIConstants.autoOrgMinTabCount {
            tabGroups = [TabGroup(id: "0", tabIDs: regularTabIDs)]
        } else {
            // we have enough to make groups
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
                let name = currentGroupName
                tabGroups.append(TabGroup(
                    id: "group-\(name ?? "")-\(tabGroups.count)",
                    name: name,
                    tabIDs: currentGroupTabs
                ))
            }
        }
        
        self.regularTabGroups = tabGroups
        
        // Check if there are downloads
        self.hasDownloads = !(perProfileData?.downloads.isEmpty ?? true)
    }
}

private struct SidebarContent: View {
    var snapshot: SidebarSnapshot
    var floating: Bool
    @State private var pageTransitionAmount: CGFloat = 0 // Add for animation effect
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.profiles
        } main: { profiles in
            TabView(selection: Binding(
                get: { snapshot.profileID },
                set: { newProfileID in
                    if newProfileID != snapshot.profileID {
                        BrowserStore.shared.modify { state in
                            if state.windows[snapshot.windowID]?.perProfileData[newProfileID] == nil {
                                state.windows[snapshot.windowID]?.perProfileData[newProfileID] = WindowState.PerProfileData(tabs: [])
                            }
                            state.windows[snapshot.windowID]?.profile = newProfileID
                        }
                    }
                }
            )) {
                ForEach(profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }), id: \.id.raw) { profile in
                    ProfileSidebarContent(
                        snapshot: snapshot, 
                        profileID: profile.id,
                        floating: floating
                    )
                    .tag(profile.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: UIConstants.sidebarWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: snapshot.profileID)
            .overlay(alignment: .topLeading) {
                topButtons
                    .padding(.leading, 72)
            }
            .overlay(alignment: .bottom) {
                profileIndicator(profiles: profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }))
                    .padding(.bottom, 4)
            }
            .contextMenu {
                ProfilePicker(
                    currentProfileID: snapshot.profileID,
                    windowID: snapshot.windowID
                )
            }
        }
    }
    
    // Profile indicator dots at the bottom
    @ViewBuilder
    private func profileIndicator(profiles: [Profile]) -> some View {
        HStack(spacing: 4) {
            ForEach(profiles, id: \.id.raw) { profile in
                Circle()
                    .fill(profile.id == snapshot.profileID ? Color.accentColor : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
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

private struct ProfileSidebarContent: View {
    var snapshot: SidebarSnapshot
    var profileID: ID<Profile>
    var floating: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            if floating {
                Spacer().frame(height: 30)
            }
            
            // Create a profile-specific snapshot
            WithSnapshotMain(store: BrowserStore.shared) { state in
                SidebarSnapshot(
                    windowID: snapshot.windowID,
                    profileID: profileID, // Use the specific profile
                    windows: state.windows,
                    tabs: state.tabs,
                    profiles: state.profiles
                )
            } main: { profileSnapshot in
                VStack(spacing: 0) {
                    // Favorite bookmarks/tabs section
                    FavoriteTabsView(
                        tabIDs: profileSnapshot.favoriteTabIDs,
                        currentTabID: profileSnapshot.currentTabID,
                        windowID: profileSnapshot.windowID
                    )
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                    
                    GroupedTabsView(
                        tabGroups: profileSnapshot.regularTabGroups,
                        currentTabID: profileSnapshot.currentTabID,
                        windowID: profileSnapshot.windowID
                    )
                    
                    // Downloads section
                    if profileSnapshot.hasDownloads {
                        DownloadsSidebar(windowID: profileSnapshot.windowID)
                    }
                    
                    Spacer()
                    
                    // Bottom buttons
                    SidebarBottomButtons(windowID: profileSnapshot.windowID)
                        .padding(.bottom, 8)
                }
            }
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

private enum TabListCell: Equatable, Identifiable {
    case header(id: String, name: String?) // if name is nil, .render as divider
    case tabID(ID<Tab>)
    
    var id: String {
        switch self {
        case .header(let id, _):
            return id
        case .tabID(let id):
            return id.raw
        }
    }
    
    static func cellsFrom(groups: [TabGroup]) -> [TabListCell] {
        var cells = [TabListCell]()
        var isFirst = true
        for group in groups {
            if let name = group.name {
                cells.append(.header(id: "header:" + group.id, name: name))
            } else if !isFirst {
                // Append non-textual (divider) header
                cells.append(.header(id: "header:" + group.id, name: nil))
            }
            cells += group.tabIDs.map { TabListCell.tabID($0) }
            isFirst = false
        }
        return cells
    }
}

// Grouped tabs section
private struct GroupedTabsView: View {
    let tabGroups: [TabGroup]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    
    var body: some View {
        let cells: [TabListCell] = TabListCell.cellsFrom(groups: tabGroups)
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cells) { cell in
                        switch cell {
                        case .header(id: _, name: let name):
                            if let name {
                                GroupHeader(name: name)
                            } else {
                                Divider()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                            }
                        case .tabID(let tabID):
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
                }
                .frame(maxWidth: .infinity)
                .animation(.niceDefault(duration: 0.12), value: tabGroups)
            }
            // Background drop target for the entire area
            .sidebarDropTarget { point, bounds in
                // Drop at the end of the window's regular tabs
                return .ordinaryTabs(window: windowID, before: nil)
            }
            .onChange(of: currentTabID) { newTabID in
                if let newTabID = newTabID {
                    withAnimation(.niceDefault) {
                        scrollProxy.scrollTo(newTabID, anchor: nil)
                    }
                }
            }
            .onAppear {
                if let currentTabID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            scrollProxy.scrollTo(currentTabID, anchor: nil)
                        }
                    }
                }
            }
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

// Profile picker for context menu
private struct ProfilePicker: View {
    let currentProfileID: ID<Profile>
    let windowID: ID<WindowState>
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.profiles
        } main: { profiles in
            Group {
                ForEach(profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }), id: \.id.raw) { profile in
                    Button {
                        switchToProfile(profileID: profile.id)
                    } label: {
                        Text(profile.id.raw)
                    }
                }
                
                Divider()
                
                Button("New Profile") {
                    createNewProfile()
                }
            }
        }
    }
    
    private func createNewProfile() {
        BrowserStore.shared.modify { state in
            let newProfileID = state.createNewProfile()
            state.windows[windowID]?.profile = newProfileID
        }
    }
    
    private func switchToProfile(profileID: ID<Profile>) {
        BrowserStore.shared.modify { state in
            if state.windows[windowID]?.perProfileData[profileID] == nil {
                state.windows[windowID]?.perProfileData[profileID] = WindowState.PerProfileData(tabs: [])
            }
            state.windows[windowID]?.profile = profileID
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
