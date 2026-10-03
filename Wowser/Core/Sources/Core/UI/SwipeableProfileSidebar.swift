import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct SidebarSwipeView: View {
    let windowID: ID<WindowState>
    
    @State private var selectedProfileID: String?
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            SidebarSwipeSnapshot(
                profileIDs: state.visibleProfiles.map(\.id),
                currentProfileID: state.windows[windowID]?.profile ?? .init(raw: "p0"),
                showingNewProfilePage: state.windows[windowID]?.showingNewProfilePage == true
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
    /// Visible profiles in carousel order.
    let profileIDs: [ID<Profile>]
    let currentProfileID: ID<Profile>
    let showingNewProfilePage: Bool
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
                        .id(Self.newProfilePageID)
                }
            }
            .scrollTargetLayout()
            .scrollTargetBehavior(.paging)
//            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedProfileID)
            .onAppear {
                // Initialize the selectedProfileID to the current profile when view appears
                selectedProfileID = snapshot.showingNewProfilePage ? Self.newProfilePageID : snapshot.currentProfileID.raw
            }
            .onChange(of: selectedProfileID) { oldValue, newValue in
                if newValue == Self.newProfilePageID {
                    if !snapshot.showingNewProfilePage { setShowingNewProfilePage(true) }
                } else if let idString = newValue, idString != snapshot.currentProfileID.raw {
                    // When user swipes to a different profile, update the current profile
                    switchToProfile(ID<Profile>(raw: idString))
                } else if snapshot.showingNewProfilePage {
                    setShowingNewProfilePage(false)
                }
            }
            .onChange(of: snapshot.showingNewProfilePage) { _, showing in
                // Something else (a paging dot, Settings' "New Profile…") moved
                // on or off the new-profile page.
                if showing, selectedProfileID != Self.newProfilePageID {
                    selectedProfileID = Self.newProfilePageID
                } else if !showing, selectedProfileID == Self.newProfilePageID {
                    selectedProfileID = snapshot.currentProfileID.raw
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
            if snapshot.profileIDs.count > 1 || snapshot.showingNewProfilePage {
                ProfilePagingDots(windowID: windowID)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
    }
    
    private static let newProfilePageID = "new-profile"

    private func switchToProfile(_ profileID: ID<Profile>) {
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.profile = profileID
            state.windows[windowID]?.showingNewProfilePage = nil
        }
    }

    private func setShowingNewProfilePage(_ showing: Bool) {
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.showingNewProfilePage = showing ? true : nil
        }
    }
}

// View for a single profile page in the swipe view
private struct ProfilePageView: View {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    @AppStorage(DefaultsKeys.allWindowsShareTabs.rawValue) private var allWindowsShareTabs = true
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            ProfilePageSnapshot(
                windowID: windowID,
                profileID: profileID,
                shareTabsAcrossWindows: allWindowsShareTabs,
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
    /// Folder tabs in this space's list, keyed by tab id.
    let folders: [ID<Tab>: FolderSnapshot]
    let regularTabGroups: [TabGroup]
    let currentTabID: ID<Tab>?
    /// Chat mode: the tab list is replaced by the coordinator thread.
    let chatMode: Bool

    init(windowID: ID<WindowState>, profileID: ID<Profile>, shareTabsAcrossWindows: Bool, state: BrowserState) {
        self.windowID = windowID
        self.profileID = profileID
        self.chatMode = state.isChatMode
        
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
        let regularTabIDs = shareTabsAcrossWindows
            ? state.sharedSidebarTabIDs(windowID: windowID, profileID: profileID)
            : (perProfileData?.tabs ?? [])
        var folders = [ID<Tab>: FolderSnapshot]()
        for tabID in regularTabIDs {
            if let tab = state.tabs[tabID], let snap = FolderSnapshot(folderTab: tab, tabs: state.tabs) {
                folders[tabID] = snap
            }
        }
        self.folders = folders
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
            }

            if snapshot.chatMode {
                ChatSpaceSidebar(windowID: windowID, profileID: snapshot.profileID)
            } else {
                // Regular tabs section with group headers
                GroupedTabsView(
                    folders: snapshot.folders,
                    tabGroups: snapshot.regularTabGroups,
                    currentTabID: snapshot.currentTabID,
                    windowID: windowID,
                    profileID: snapshot.profileID
                )
            }
        }
    }
}

// View for the "new profile" page
private struct NewProfileView: View {
    let windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            NewProfileSnapshot(state: state)
        } main: { snapshot in
            NewProfileContent(snapshot: snapshot, windowID: windowID)
        }
    }
}

private struct NewProfileSnapshot: Equatable {
    /// Just what the sharing menu needs from each visible profile.
    struct Entry: Equatable {
        var id: ID<Profile>
        var displayName: String
    }
    /// See `BrowserState.loginGroups`.
    var loginGroups: [[Entry]]
    var lastProfileID: ID<Profile>?

    init(state: BrowserState) {
        loginGroups = state.loginGroups.map { group in
            group.map { Entry(id: $0.id, displayName: $0.displayName) }
        }
        lastProfileID = state.visibleProfiles.last?.id
    }

    func contains(_ id: ID<Profile>) -> Bool { loginGroup(for: id) != nil }

    // The group of profiles that share logins with the given profile.
    func loginGroup(for id: ID<Profile>) -> [Entry]? {
        loginGroups.first(where: { $0.contains(where: { $0.id == id }) })
    }
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
            if case .shareLogins(let id) = pickedChoice, !snapshot.contains(id) {
                return defaultChoice
            }
            return pickedChoice
        }
        return defaultChoice
    }

    private var defaultChoice: NewProfileSharingChoice {
        if let lastProfileID = snapshot.lastProfileID {
            return .shareLogins(lastProfileID)
        }
        return .isolated
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                HStack {
                    Text("New Profile")
                        .font(.headline)
                    Spacer()
                }
                
                Divider()
                    .padding(.horizontal, -16)
                
                profileSharingMenu
                
                Button(action: createNewProfile) {
                    Text("New Profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .padding(12)
            .background {
                RecessedSidebarShape(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            
            #if os(macOS)
            Button(action: createProfileFromFolder) {
                Text("From Folder…")
                    .padding(4)
            }
            .buttonStyle(GhostButtonStyle())

            #endif
        }
        .padding()
    }

    @ViewBuilder private var profileSharingMenu: some View {
        Menu {
            ForEach(snapshot.loginGroups, id: \.first?.id.raw) { group in
                if let representative = group.first {
                    Button(shareLoginsLabel(for: group)) {
                        pickedChoice = .shareLogins(representative.id)
                    }
                }
            }
            Divider()
            Button("Isolated profile") {
                pickedChoice = .isolated
            }
        } label: {
            Text(label(for: resolvedChoice))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .controlSize(.small)
    }

    private func shareLoginsLabel(for group: [NewProfileSnapshot.Entry]) -> String {
        let names = group.map(\.displayName)
        return "Share logins with \(joinedNames(names))"
    }

    // Joins names with commas and a trailing "and": "A", "A and B", "A, B and C".
    private func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names.last!)"
        }
    }

    private func label(for choice: NewProfileSharingChoice) -> String {
        switch choice {
        case .shareLogins(let id):
            if let group = snapshot.loginGroup(for: id) {
                return shareLoginsLabel(for: group)
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
            state.windows[windowID]?.showingNewProfilePage = nil
        }
    }

    private var sourceProfileIDForSharing: ID<Profile>? {
        switch resolvedChoice {
        case .shareLogins(let id): return id
        case .isolated: return nil
        }
    }

    #if os(macOS)
    // Picks a folder (new folders allowed) and makes a profile named after it,
    // pre-pinned with VS Code / terminal / files tabs for that folder.
    private func createProfileFromFolder() {
        let sourceID = sourceProfileIDForSharing
        FolderPicker.pick(prompt: "Create Profile", message: "Choose a folder for the new profile") { path in
            BrowserStore.shared.modify { state in
                let newProfileId = state.createNewProfile(forFolderPath: path, sharingLoginsWith: sourceID)
                state.windows[windowID]?.profile = newProfileId
                state.windows[windowID]?.showingNewProfilePage = nil
            }
        }
    }
    #endif
}

// Helper extension to safely access array elements
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
