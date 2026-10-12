#if os(macOS)
import SwiftUI

/// The screens of the first-run flow, in order. See the outline at the top of
/// OnboardingKit.swift.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case importData
    case defaultBrowser
    case ai
    case limitations
    case goodies
    case projects
    case tricks
}

/// The whole onboarding flow, shown in the welcome tab. Finishing (or
/// skipping) marks onboarding complete and closes the tab.
struct OnboardingFlow: View {
    /// The welcome tab's pane, closed when the user finishes.
    var webContentID: ID<WebContent>?

    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            screen(for: step)
                .id(step)
                .transition(.onboardingScreen)
        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            if step != .tricks {
                Button("Skip setup", action: finish)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private func screen(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: OnboardingWelcomeScreen(next: advance)
        case .importData: OnboardingImportScreen(next: advance)
        case .defaultBrowser: OnboardingDefaultBrowserScreen(next: advance)
        case .ai: OnboardingAIScreen(next: advance)
        case .limitations: OnboardingLimitationsScreen(next: advance)
        case .goodies: OnboardingGoodiesScreen(next: advance)
        case .projects: OnboardingProjectsScreen(next: advance)
        case .tricks: OnboardingTricksScreen(done: finish)
        }
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            step = next
        }
    }

    private func finish() {
        DefaultsKeys.hasCompletedOnboarding.setBool(true)
        if let webContentID {
            BrowserStore.shared.close(webContentId: webContentID, removeIfPinned: false)
        }
    }
}

#Preview {
    OnboardingFlow()
        .frame(width: 900, height: 700)
}
#endif
