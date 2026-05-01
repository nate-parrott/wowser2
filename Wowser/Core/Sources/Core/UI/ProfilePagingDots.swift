import SwiftUI

/// A view that displays a series of dots/indicators representing profiles in the carousel
/// with right-click menu for emoji selection
public struct ProfilePagingDots: View {
    let windowID: ID<WindowState>
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            ProfilePagingDotsSnapshot(
                windowID: windowID,
                profiles: state.profiles,
                currentProfileID: state.windows[windowID]?.profile ?? .init(raw: "p0")
            )
        } main: { snapshot in
            ProfilePagingDotsContent(
                snapshot: snapshot,
                windowID: windowID
            )
        }
    }
}

private struct ProfilePagingDotsSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profiles: [ID<Profile>: Profile]
    let currentProfileID: ID<Profile>
    
    var orderedProfileIDs: [ID<Profile>] {
        profiles.values
            .sorted(by: { $0.creationOrder < $1.creationOrder })
            .map(\.id)
    }
}

private struct ProfilePagingDotsContent: View {
    let snapshot: ProfilePagingDotsSnapshot
    let windowID: ID<WindowState>
    
    var body: some View {
        // Only show paging dots if we have more than one profile
        if snapshot.orderedProfileIDs.count > 1 {
            HStack(spacing: 8) {
                ForEach(snapshot.orderedProfileIDs, id: \.raw) { profileID in
                    ProfileDotView(
                        profileID: profileID,
                        isSelected: profileID == snapshot.currentProfileID,
                        windowID: windowID,
                        profile: snapshot.profiles[profileID]
                    )
                }
            }
            .padding(.vertical, 8)
        } else {
            // No need to show paging dots if there's only one profile
            EmptyView()
        }
    }
}

private struct ProfileDotView: View {
    let profileID: ID<Profile>
    let isSelected: Bool
    let windowID: ID<WindowState>
    let profile: Profile?
    
    @State private var showingEmojiMenu = false
    
    var body: some View {
        Button(action: {
            // Switch to this profile when clicked
            switchToProfile()
        }) {
            ZStack {
                // Background circle for consistent sizing
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .frame(width: 24, height: 24)
                
                if let emoji = profile?.emoji, !emoji.isEmpty {
                    // Display the emoji if it's been set
                    Text(emoji)
                        .font(.system(size: 14))
                        .opacity(isSelected ? 1.0 : 0.6)
                } else {
                    // Default dot indicator
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {}) {
                Text("Set Profile Icon")
            }
            .disabled(true)
            
            Button(action: {
                setProfileEmoji("📓")
                setProfileTitle("School")
            }) {
                Text("📓 School")
            }
            
            Button(action: {
                setProfileEmoji("💼")
                setProfileTitle("Work")
            }) {
                Text("💼 Work")
            }
            
            Button(action: {
                setProfileEmoji("🎮")
                setProfileTitle("Gaming")
            }) {
                Text("🎮 Gaming")
            }
            
            Button(action: {
                setProfileEmoji("🎬")
                setProfileTitle("Streaming")
            }) {
                Text("🎬 Streaming")
            }
            
            Button(action: {
                setProfileEmoji("📚")
                setProfileTitle("Research")
            }) {
                Text("📚 Research")
            }
            
            Button(action: {
                setProfileEmoji("✈️")
                setProfileTitle("Travel")
            }) {
                Text("✈️ Travel")
            }
            
            Button(action: {
                setProfileEmoji("🏠")
                setProfileTitle("Home")
            }) {
                Text("🏠 Home")
            }
            
            Button(action: {
                setProfileEmoji("💵")
                setProfileTitle("Money")
            }) {
                Text("💵 Money")
            }
            
            Button(action: {
                setProfileEmoji("🔒")
                setProfileTitle("Private")
            }) {
                Text("🔒 Private")
            }
            
            Button(action: {
                setProfileEmoji("😀")
                setProfileTitle("Just Browsing")
            }) {
                Text("😀 Just Browsing")
            }
            
            Divider()
            
            Button(action: {
                // Clear emoji and title
                setProfileEmoji(nil)
                setProfileTitle(nil)
            }) {
                Text("Clear Icon")
            }
            
            Divider()
            
            // Only show Delete Profile if we have more than one profile
            if canDeleteProfile() {
                Button(action: {
                    deleteProfile()
                }) {
                    Text("Delete Profile")
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    private func switchToProfile() {
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.profile = profileID
        }
    }
    
    private func setProfileEmoji(_ emoji: String?) {
        BrowserStore.shared.modify { state in
            state.profiles[profileID]?.emoji = emoji
        }
    }
    
    private func setProfileTitle(_ title: String?) {
        BrowserStore.shared.modify { state in
            state.profiles[profileID]?.title = title
        }
    }
    
    private func canDeleteProfile() -> Bool {
        // Check if we have more than one profile (we never want to delete the last profile)
        let profileCount = BrowserStore.shared.model.profiles.count
        return profileCount > 1
    }
    
    private func deleteProfile() {
        // We need to:
        // 1. Close all tabs in this profile
        // 2. Switch to another profile if this is the current one
        // 3. Remove the profile
        BrowserStore.shared.modify { state in
            // Find all tabs that belong to this profile
            let windowsUsingThisProfile = state.windows.values.filter { $0.profile == profileID }
            for window in windowsUsingThisProfile {
                // Get all tabs in this window for this profile
                let tabsToClose = window.perProfileData[profileID]?.tabs ?? []
                
                // Remove the tabs from state
                for tabID in tabsToClose {
                    state._removeTab_unsafe_doesntCloseWebContent(tabId: tabID)
                }
                
                // If this is the current profile in the window, switch to another profile
                if window.profile == profileID {
                    // Find another profile to switch to
                    let anotherProfile = state.profiles.values
                        .first(where: { $0.id != profileID })?.id ?? .defaultProfile
                    
                    // Switch to the other profile
                    state.windows[window.id]?.profile = anotherProfile
                }
                
                // Clear per-profile data
                state.windows[window.id]?.perProfileData.removeValue(forKey: profileID)
            }
            
            // Remove the profile itself
            state.profiles.removeValue(forKey: profileID)
        }
    }
}
