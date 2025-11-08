import SwiftUI

public struct SidebarSwipeView: View {
    let windowID: ID<WindowState>
    
    @State private var selectedProfileID: String?
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            SidebarSwipeSnapshot(
                windowID: windowID,
                profiles: state.profiles,
                currentProfileID: state.windows[windowID]?.profile ?? .init(raw: "p0")
            )
        } main: { snapshot in
            SidebarSwipeContent(
                snapshot: snapshot,
                windowID: windowID,
                selectedProfileID: $selectedProfileID
            )
        }
    }
}

private struct SidebarSwipeSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profiles: [ID<Profile>: Profile]
    let currentProfileID: ID<Profile>
    
    var profileIDs: [ID<Profile>] {
        profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }).map({ $0.id })
    }
}

private struct SidebarSwipeContent: View {
    let snapshot: SidebarSwipeSnapshot
    let windowID: ID<WindowState>
    @Binding var selectedProfileID: String?
    @State private var width = UIConstants.sidebarWidth
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(snapshot.profileIDs, id: \.raw) { profileID in
                        ProfilePageView(
                            windowID: windowID,
                            profileID: profileID
                        )
                        .frame(width: width)
                        .id(profileID.raw)
                    }
                    
                    NewProfileView(windowID: windowID)
                        .frame(width: width)
                        .id("new-profile")
                }
            }
            .scrollTargetLayout()
            .scrollTargetBehavior(.viewAligned)
//            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedProfileID)
            .onAppear {
                // Initialize the selectedProfileID to the current profile when view appears
                selectedProfileID = snapshot.currentProfileID.raw
            }
            .onChange(of: selectedProfileID) { oldValue, newValue in
                if let idString = newValue, idString != "new-profile", idString != snapshot.currentProfileID.raw {
                    // When user swipes to a different profile, update the current profile
                    switchToProfile(ID<Profile>(raw: idString))
                }
            }
            .onChange(of: snapshot.currentProfileID) { oldValue, newValue in
                // When the current profile changes in the store, update the selected profile ID
                if selectedProfileID != newValue.raw {
                    selectedProfileID = newValue.raw
                }
            }
            .measureSize({ width = $0.width })
            
            // Add the paging dots below the carousel
            if snapshot.profileIDs.count > 1 {
                ProfilePagingDots(windowID: windowID)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
    }
    
    private func switchToProfile(_ profileID: ID<Profile>) {
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.profile = profileID
        }
    }
}

// View for a single profile page in the swipe view
private struct ProfilePageView: View {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    
    var body: some View {
        // Use reactive programming to observe the profile's data
        WithSnapshotMain(store: BrowserStore.shared) { state in
            ProfilePageSnapshot(
                windowID: windowID,
                profileID: profileID,
                state: state
            )
        } main: { snapshot in
            ProfilePageContent(snapshot: snapshot, windowID: windowID)
        }
        .environment(\.profileID, profileID)
    }
}

private struct ProfilePageSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    let favoriteTabIDs: [ID<Tab>]
    let regularTabGroups: [TabGroup]
    let currentTabID: ID<Tab>?
    
    init(windowID: ID<WindowState>, profileID: ID<Profile>, state: BrowserState) {
        self.windowID = windowID
        self.profileID = profileID
        
        // Extract favorites from profile
        var favoriteIDs = [ID<Tab>]()
        if let profile = state.profiles[profileID] {
            favoriteIDs = profile.manualFavorites + profile.autoFavorites
        }
        self.favoriteTabIDs = favoriteIDs
        
        // Get per-profile data from window state
        let window = state.windows[windowID]
        let perProfileData = window?.perProfileData[profileID]
        
        // Get profile-specific current tab
        self.currentTabID = perProfileData?.currentTab
        
        // Process tabs in their original order but add headers when group changes
        let regularTabIDs = perProfileData?.tabs ?? []
        var tabGroups: [TabGroup] = []
        
        if regularTabIDs.count < UIConstants.autoOrgMinTabCount {
            tabGroups = [TabGroup(id: "0", tabIDs: regularTabIDs)]
        } else {
            // we have enough to make groups
            var currentGroupName: String? = nil
            var currentGroupTabs: [ID<Tab>] = []
            
            // Go through tabs one by one in their original order
            for tabID in regularTabIDs {
                let tabGroupName = state.tabs[tabID]?.aiTags?.groupName
                
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
    }
}

private struct ProfilePageContent: View {
    let snapshot: ProfilePageSnapshot
    let windowID: ID<WindowState>
    
    var body: some View {
        VStack(spacing: 0) {
            // Favorite bookmarks/tabs section
            
            if snapshot.favoriteTabIDs.count > 0 || isDesktop() {
                FavoriteTabsView(
                    tabIDs: snapshot.favoriteTabIDs,
                    currentTabID: snapshot.currentTabID,
                    windowID: windowID
                )
                .padding(.top, 5)
                .padding(.bottom, 10)
            }
            
            // Regular tabs section with group headers
            GroupedTabsView(
                tabGroups: snapshot.regularTabGroups,
                currentTabID: snapshot.currentTabID,
                windowID: windowID
            )
        }
    }
}

// View for the "new profile" page
private struct NewProfileView: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        FreeformButton(action: createNewProfile) { status in
            let bgOpacity: CGFloat = status == .pressed ? 0.1 : (status == .hovered ? 0.07 : 0)
            VStack(spacing: 22) {
                Image(systemName: "plus")
                    .font(.system(size: 32))
                
                Text("New Profile")
                    .fontWeight(.medium)
            }
            .padding()
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(bgOpacity)))
            .foregroundStyle(.secondary)
            .padding()
        }
        .frame(width: UIConstants.sidebarWidth)
//        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func createNewProfile() {
        BrowserStore.shared.modify { state in
            let newProfileId = state.createNewProfile()
            state.windows[windowID]?.profile = newProfileId
            // The reactive binding will automatically detect the profile change
            // and update the selected profile ID
        }
    }
}

// Helper extension to safely access array elements
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
