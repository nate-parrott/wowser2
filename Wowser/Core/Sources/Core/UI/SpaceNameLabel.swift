import SwiftUI

/// Label in the sidebar's chrome row (between the traffic lights and the
/// sidebar button) displaying the current space's name. Clicking it opens a
/// rename prompt (see `SpaceMenu.rename`).
struct SpaceNameLabel: View {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            let profile = state.profiles[profileID]
            return SpaceNameSnapshot(
                title: profile?.title,
                autoTitle: profile?.autoTitle,
                emoji: profile?.emoji,
                creationOrder: profile?.creationOrder ?? 0
            )
        } main: { snapshot in
            SpaceNameButton(snapshot: snapshot, windowID: windowID, profileID: profileID)
        }
    }
}

private struct SpaceNameSnapshot: Equatable {
    var title: String?
    var autoTitle: String?
    var emoji: String?
    var creationOrder: Int

    /// Shown when there's no user-entered title: the AI-generated name if we
    /// have one, otherwise a generic fallback.
    var placeholder: String {
        autoTitle ?? "Space \(creationOrder + 1)"
    }
}

private struct SpaceNameButton: View {
    let snapshot: SpaceNameSnapshot
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    var body: some View {
        HStack(spacing: 2) {
            SpaceIconMenuButton(profileID: profileID, windowID: windowID, emoji: snapshot.emoji)
            
            let hasTitle = snapshot.title?.nilIfEmpty != nil
            Text(snapshot.title?.nilIfEmpty ?? snapshot.placeholder)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(hasTitle ? 1 : 0.5)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20)
                .contentShape(Rectangle())
                .help("Rename Space")
                .onHover(perform: { hovered in
                    if hovered {
                        NSCursor.iBeam.push()
                    } else {
                        NSCursor.iBeam.pop()
                    }
                })
                .onTapGesture {
                    SpaceMenu.rename(profileID: profileID)
                }

//            Button {
//                SpaceMenu.rename(profileID: profileID)
//            } label: {
//                let hasTitle = snapshot.title?.nilIfEmpty != nil
//                Text(snapshot.title?.nilIfEmpty ?? snapshot.placeholder)
//                    .font(.system(size: 11, weight: .semibold))
//                    .foregroundStyle(.secondary)
//                    .opacity(hasTitle ? 1 : 0.5)
//                    .lineLimit(1)
//                    .truncationMode(.tail)
//                    .padding(.leading, 5)
//                    .frame(maxWidth: .infinity, alignment: .leading)
//                    .frame(height: 20)
//                    .contentShape(Rectangle())
//            }
//            .buttonStyle(.plain)
//            .help("Rename Space")
        }
    }
}
