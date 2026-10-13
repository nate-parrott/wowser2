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

/// Where the flow is, plus each screen's in-progress inputs. Kept in
/// `NativeRenderCache` under the welcome pane's id, so switching tabs (which
/// unmounts the page) doesn't send the user back to the start. Not persisted.
@Observable
final class OnboardingModel {
    var step: OnboardingStep = .welcome
    /// Last step change went backwards (picks the push direction).
    var wentBack = false
    var importState = OnboardingImportState()
    var ai = OnboardingAIState()
    var projects = OnboardingProjectsState()
    var tricks = OnboardingTricksState()

    /// The model for `webContentID`'s welcome page, created on first use.
    static func cached(for webContentID: ID<WebContent>?) -> OnboardingModel {
        guard let key = webContentID?.raw else { return OnboardingModel() }
        if let existing = NativeRenderCache.shared.get(OnboardingModel.self, id: key) {
            return existing
        }
        let model = OnboardingModel()
        NativeRenderCache.shared.set(model, id: key)
        return model
    }
}

/// The whole onboarding flow, shown in the welcome tab. Finishing marks
/// onboarding complete and moves on to a new tab (the welcome tab stays; the
/// user can close it like any other).
struct OnboardingFlow: View {
    /// The welcome tab's pane.
    var webContentID: ID<WebContent>?

    @Environment(\.windowID) private var windowID

    @State private var model: OnboardingModel

    init(webContentID: ID<WebContent>?) {
        self.webContentID = webContentID
        _model = State(initialValue: OnboardingModel.cached(for: webContentID))
    }

    var body: some View {
        ZStack {
            screen(for: model.step)
                .id(model.step)
                .transition(.push(from: model.wentBack ? .leading : .trailing))
                .environment(\.onboardingBack, model.step == .welcome ? nil : goBack)
        }
        .clipped()
    }

    @ViewBuilder
    private func screen(for step: OnboardingStep) -> some View {
        @Bindable var model = model
        switch step {
        case .welcome: OnboardingWelcomeScreen(next: advance)
        case .importData: OnboardingImportScreen(state: $model.importState, next: advance)
        case .defaultBrowser: OnboardingDefaultBrowserScreen(next: advance)
        case .ai: OnboardingAIScreen(state: $model.ai, next: advance)
        case .limitations: OnboardingLimitationsScreen(next: advance)
        case .goodies: OnboardingGoodiesScreen(next: advance)
        case .projects: OnboardingProjectsScreen(state: $model.projects, next: advance)
        case .tricks: OnboardingTricksScreen(state: $model.tricks, done: finish)
        }
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: model.step.rawValue + 1) else {
            finish()
            return
        }
        go(to: next, back: false)
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: model.step.rawValue - 1) else { return }
        go(to: previous, back: true)
    }

    private func go(to step: OnboardingStep, back: Bool) {
        model.wentBack = back
        withAnimation(.easeInOut(duration: 0.3)) {
            model.step = step
        }
    }

    private func finish() {
        DefaultsKeys.hasCompletedOnboarding.setBool(true)
        let windowID = self.windowID
        BrowserStore.shared.modify { $0.openOrSelectNewTab(windowID: windowID) }
    }
}

#Preview {
    OnboardingFlow(webContentID: nil)
        .frame(width: 900, height: 700)
}
#endif
