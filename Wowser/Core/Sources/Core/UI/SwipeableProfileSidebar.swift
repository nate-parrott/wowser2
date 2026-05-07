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
        WithSnapshotMain(store: BrowserStore.shared) { state in
            NewProfileSnapshot(profiles: state.profiles)
        } main: { snapshot in
            NewProfileContent(snapshot: snapshot, windowID: windowID)
        }
    }
}

private struct NewProfileSnapshot: Equatable {
    var profiles: [ID<Profile>: Profile]

    var sortedProfiles: [Profile] {
        profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder })
    }

    var lastProfile: Profile? { sortedProfiles.last }
}

private enum NewProfileSharingChoice: Hashable {
    case shareLogins(ID<Profile>)
    case isolated
}

private struct NewProfileContent: View {
    let snapshot: NewProfileSnapshot
    let windowID: ID<WindowState>

    @State private var pickedChoice: NewProfileSharingChoice?

    private var resolvedChoice: NewProfileSharingChoice {
        if let pickedChoice {
            // If the picked profile no longer exists, fall back.
            if case .shareLogins(let id) = pickedChoice, snapshot.profiles[id] == nil {
                return defaultChoice
            }
            return pickedChoice
        }
        return defaultChoice
    }

    private var defaultChoice: NewProfileSharingChoice {
        if let last = snapshot.lastProfile {
            return .shareLogins(last.id)
        }
        return .isolated
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
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
            }
//            Divider()
//                .padding(.horizontal)
            
            profileSharingMenu
            .opacity(0.5)
            .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding()
        .frame(width: UIConstants.sidebarWidth)
    }
    
    @ViewBuilder private var profileSharingMenu: some View {
        Menu {
            ForEach(snapshot.sortedProfiles, id: \.id.raw) { profile in
                Button(shareLoginsLabel(for: profile)) {
                    pickedChoice = .shareLogins(profile.id)
                }
            }
            Divider()
            Button("Isolated profile") {
                pickedChoice = .isolated
            }
        } label: {
            HStack {
                Text(label(for: resolvedChoice))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
    }

    private func displayName(for profile: Profile) -> String {
        profile.title ?? profile.emoji ?? "Profile \(profile.creationOrder + 1)"
    }

    private func shareLoginsLabel(for profile: Profile) -> String {
        "Share logins with \(displayName(for: profile))"
    }

    private func label(for choice: NewProfileSharingChoice) -> String {
        switch choice {
        case .shareLogins(let id):
            if let profile = snapshot.profiles[id] {
                return shareLoginsLabel(for: profile)
            }
            return "Share logins"
        case .isolated:
            return "Isolated profile"
        }
    }

    private func createNewProfile() {
        let choice = resolvedChoice
        BrowserStore.shared.modify { state in
            let sourceID: ID<Profile>?
            switch choice {
            case .shareLogins(let id): sourceID = id
            case .isolated: sourceID = nil
            }
            let newProfileId = state.createNewProfile(sharingLoginsWith: sourceID)
            state.windows[windowID]?.profile = newProfileId
        }
    }
}

// Helper extension to safely access array elements
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
