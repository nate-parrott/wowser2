#if os(macOS)
import SwiftUI

/// "Pick a background": the bundled wallpapers (click to apply, or drag onto
/// the sidebar — the same drop the sidebar accepts for any image), plus plain
/// options: no background at all, or a flat color wash.
struct OnboardingBackgroundScreen: View {
    var next: () -> Void

    @Environment(\.windowID) private var windowID

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(
                    title: "Pick a background",
                    subtitle: "Drag any image onto the sidebar to make it this space's background. Try it with one of these, or just click one."
                )
                WithSnapshotMain(store: BrowserStore.shared, snapshot: { OnboardingBackgroundSnapshot(state: $0, windowID: windowID) }) { snapshot in
                    if let snapshot {
                        OnboardingBackgroundPicker(snapshot: snapshot)
                    }
                }
            }
        }, footer: {
            Button("Continue", action: next)
                .keyboardShortcut(.defaultAction)
        })
    }
}

struct OnboardingBackgroundSnapshot: Equatable {
    var profileID: ID<Profile>
    var builtinID: String?
    var hasImage: Bool
    var themeHue: Double?

    init?(state: BrowserState, windowID: ID<WindowState>?) {
        guard let profileID = windowID.flatMap({ state.windows[$0]?.profile }) ?? state.activeWindow?.profile,
              let profile = state.profiles[profileID] else { return nil }
        self.profileID = profileID
        builtinID = profile.imageInfo?.builtinID
        hasImage = profile.imageInfo != nil
        themeHue = profile.theme?.hue
    }
}

extension BrowserState {
    /// "Plain" background choices: drops the space's image and sets (or
    /// clears) its color wash.
    mutating func setPlainSpaceStyle(profileID: ID<Profile>, palette: SpacePalette?) {
        profiles[profileID]?.theme = palette?.theme
    }
}

private struct OnboardingBackgroundPicker: View {
    var snapshot: OnboardingBackgroundSnapshot

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(BuiltinSpaceBackground.all) { background in
                    OnboardingBackgroundTile(
                        background: background,
                        selected: snapshot.builtinID == background.id,
                        apply: { BrowserStore.shared.setBuiltinSpaceBackground(background, profileID: snapshot.profileID) }
                    )
                }
            }
            .frame(maxWidth: 600, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Or keep it plain")
                    .foregroundStyle(.secondary)
                OnboardingFlowLayout(spacing: 10) {
                    OnboardingPlainSwatch(
                        fill: AnyShapeStyle(Color.primary.opacity(0.06)),
                        selected: !snapshot.hasImage && snapshot.themeHue == nil,
                        help: "No background",
                        apply: { applyPlain(nil) }
                    )
                    ForEach(SpacePalette.allCases, id: \.self) { palette in
                        OnboardingPlainSwatch(
                            fill: AnyShapeStyle(LinearGradient(
                                colors: [
                                    Color(hue: palette.theme.secondaryHue / 360, saturation: 0.45, brightness: 0.95),
                                    Color(hue: palette.hue / 360, saturation: 0.55, brightness: 0.85),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )),
                            selected: !snapshot.hasImage && snapshot.themeHue == palette.hue,
                            help: palette.rawValue.capitalized,
                            apply: { applyPlain(palette) }
                        )
                    }
                }
            }
        }
    }

    private func applyPlain(_ palette: SpacePalette?) {
        let profileID = snapshot.profileID
        BrowserStore.shared.clearSpaceBackgroundImage(profileID: profileID)
        BrowserStore.shared.modify { $0.setPlainSpaceStyle(profileID: profileID, palette: palette) }
    }
}

/// A wallpaper: click to apply, or drag it onto the sidebar.
private struct OnboardingBackgroundTile: View {
    var background: BuiltinSpaceBackground
    var selected: Bool
    var apply: () -> Void

    // A tap gesture rather than a Button, so it doesn't compete with the
    // thumbnail's drag.
    var body: some View {
        DraggableBackgroundThumbnail(background: background, width: 150, height: 96, cornerRadius: 10)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: apply)
            .help("\(background.title) — click to use, or drag onto the sidebar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Use as background", apply)
    }
}

private struct OnboardingPlainSwatch: View {
    var fill: AnyShapeStyle
    var selected: Bool
    var help: String
    var apply: () -> Void

    var body: some View {
        Button(action: apply) {
            Circle()
                .fill(fill)
                .frame(width: 28, height: 28)
                .overlay {
                    Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
