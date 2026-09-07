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
            .filter({ !$0.isHidden })
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
            HStack(spacing: 0) {
                ForEach(snapshot.orderedProfileIDs, id: \.raw) { profileID in
                    ProfileDotView(
                        profileID: profileID,
                        isSelected: profileID == snapshot.currentProfileID,
                        windowID: windowID,
                        profile: snapshot.profiles[profileID]
                    )
                }
            }
            .padding(.top, 8)
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
    
    static let profileDragPrefix = "wowser-profile-drag:"

    @State private var hovered = false
    @State private var dropTargeted = false

    var body: some View {
        let scale = (hovered || dropTargeted) ? 1.3 : 1
        Button(action: {
            // Switch to this profile when clicked
            switchToProfile()
        }) {
            ZStack {
                // Background circle for consistent sizing
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.01))
                    .frame(width: 26, height: 26)
                
                if let emoji = profile?.emoji, !emoji.isEmpty {
                    // Display the emoji if it's been set
                    Text(emoji)
                        .font(.system(size: 12))
//                        .opacity(isSelected ? 1.0 : 0.6)
                        .scaleEffect(scale)
                } else {
                    // Default dot indicator
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover(perform: { self.hovered = $0 })
        .overlay {
            if dropTargeted {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
        }
        .onDrag {
            NSItemProvider(object: (Self.profileDragPrefix + profileID.raw) as NSString)
        }
        .onDrop(of: ["public.text"], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                DispatchQueue.main.async {
                    if string.hasPrefix(Self.profileDragPrefix) {
                        let draggedID = ID<Profile>(raw: String(string.dropFirst(Self.profileDragPrefix.count)))
                        BrowserStore.shared.modify { state in
                            state.moveProfile(draggedID, toPositionOf: profileID)
                        }
                    } else {
                        BrowserStore.shared.move(
                            tab: ID<Tab>(raw: string),
                            toSpace: profileID,
                            inWindow: windowID
                        )
                    }
                }
            }
            return true
        }
        .contextMenu {
            SpaceMenuItems(profileID: profileID, windowID: windowID)
        }
    }
    
    private func switchToProfile() {
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.profile = profileID
        }
    }
}
