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
            if let emoji = profile?.emoji, !emoji.isEmpty {
                // Display the emoji if it's been set
                Text(emoji)
                    .font(.system(size: 14))
                    .opacity(isSelected ? 1.0 : 0.6)
                    .frame(width: 24, height: 24)
                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(Circle())
            } else {
                // Default dot indicator
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {
                setProfileEmoji("😀")
                setProfileTitle("Happy")
            }) {
                Text("😀 Happy")
            }
            
            Button(action: {
                setProfileEmoji("🔥")
                setProfileTitle("Work")
            }) {
                Text("🔥 Work")
            }
            
            Button(action: {
                setProfileEmoji("🎮")
                setProfileTitle("Gaming")
            }) {
                Text("🎮 Gaming")
            }
            
            Button(action: {
                setProfileEmoji("🎬")
                setProfileTitle("Media")
            }) {
                Text("🎬 Media")
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
                setProfileEmoji("💼")
                setProfileTitle("Business")
            }) {
                Text("💼 Business")
            }
            
            Button(action: {
                setProfileEmoji("🔒")
                setProfileTitle("Private")
            }) {
                Text("🔒 Private")
            }
            
            Divider()
            
            Button(action: {
                // Clear emoji and title
                setProfileEmoji(nil)
                setProfileTitle(nil)
            }) {
                Text("Clear Custom Profile")
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
}