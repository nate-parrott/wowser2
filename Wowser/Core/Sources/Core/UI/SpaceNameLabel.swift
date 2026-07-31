import SwiftUI

/// Editable label shown at the top of each space (profile) page in the sidebar
/// swipe view, displaying that space's name. Focus is driven by the window-wide
/// focus manager via the `.spaceTitle` FocusTarget.
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
            SpaceNameField(snapshot: snapshot, windowID: windowID, profileID: profileID)
        }
    }
}

private struct SpaceNameSnapshot: Equatable {
    let title: String?
    let autoTitle: String?
    let emoji: String?
    let creationOrder: Int

    /// Shown when there's no user-entered title: the AI-generated name if we
    /// have one, otherwise a generic fallback.
    var placeholder: String {
        autoTitle ?? "Space \(creationOrder + 1)"
    }
}

private struct SpaceNameField: View {
    let snapshot: SpaceNameSnapshot
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    @State private var text: String = ""
    @State private var focusSnap = FocusSnap()

    private var focusTarget: FocusTarget {
        .spaceTitle(profile: profileID, window: windowID)
    }
    private var isEditing: Bool {
        focusSnap.target == focusTarget
    }
    private var focusDate: Date? {
        isEditing ? focusSnap.date : nil
    }
    /// Same muted tone as the section-divider headers; full-strength while editing.
    private var textColor: UINSColor {
        #if os(macOS)
        return isEditing ? .labelColor : .secondaryLabelColor
        #else
        return isEditing ? .label : .secondaryLabel
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            if let emoji = snapshot.emoji {
                Text(emoji)
                    .font(.system(size: 13))
            }
            InputTextField(
                text: $text,
                options: InputTextFieldOptions(
                    placeholder: snapshot.placeholder,
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: textColor,
                    insets: CGSize(width: 0, height: 3),
                    wantsUpDownArrowEvents: false,
                    selectAllOnFocus: true,
                    lineLimit: 1
                ),
                focusDate: focusDate,
                focusTarget: focusTarget,
                onEvent: handleEvent
            )
            // Single-line label: pin the height so the underlying scrollable
            // NSTextView doesn't expand to fill the sidebar (which would also
            // swallow clicks meant for the surrounding area).
            .frame(height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear { syncTextFromState() }
        .onChange(of: profileID) { _, _ in syncTextFromState() }
        .onChange(of: snapshot.title) { _, _ in
            // Reflect external title changes, but don't clobber in-progress edits.
            if !isEditing { syncTextFromState() }
        }
        .onReceiveFocusSnap(windowID: windowID) { self.focusSnap = $0 }
    }

    private func syncTextFromState() {
        text = snapshot.title ?? ""
    }

    private func handleEvent(_ event: TextFieldEvent) {
        switch event {
        case .focus:
            BrowserStore.shared.modify { state in
                state.didFocus(target: focusTarget)
            }
        case .blur:
            commit()
            BrowserStore.shared.modify { state in
                state.didLoseFocus(target: focusTarget)
            }
        case .key(.enter), .key(.escape):
            // Commit and hand focus back to the page; focusState then routes
            // first-responder to the web content automatically.
            commit()
            BrowserStore.shared.modify { state in
                state.didLoseFocus(target: focusTarget)
            }
        default:
            break
        }
    }

    private func commit() {
        // Only the user editing this field may change the title. Blur events
        // arrive for unrelated first-responder changes anywhere in the window
        // (including one when this view first enters it), and `text` may not
        // have been synced from state yet — committing those would silently
        // clear a user-entered title and leave the AI `autoTitle` showing.
        guard isEditing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (snapshot.title ?? "") else { return }
        BrowserStore.shared.modify { state in
            state.profiles[profileID]?.title = trimmed.isEmpty ? nil : trimmed
        }
        // Refresh the space's emoji + gradient theme from the new title.
        // No-ops if the effective title didn't actually change.
        Task {
            await BrowserStore.shared.regenerateSpaceTheme(profileID: profileID)
        }
    }
}
