import SwiftUI

/// Onboarding page (`NativePageKey.welcome`), opened in a tab on first launch
/// and from the command bar / Settings. See `OnboardingFlow`.
struct WelcomePage: View {
    /// The tab's pane; closed when onboarding finishes.
    var webContentID: ID<WebContent>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            #if os(macOS)
            OnboardingFlow(webContentID: webContentID)
            #else
            Text("Welcome")
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        }
        .background { background }
    }

    /// Dark: the usual page background. Light: a slightly translucent
    /// off-white washed with the window's tint, rather than pure white.
    @ViewBuilder
    private var background: some View {
        if colorScheme == .dark {
            Color("Background", bundle: .module)
        } else {
            ZStack {
                Color(white: 0.965).opacity(0.88)
                Color.accentColor.opacity(0.05)
            }
        }
    }
}

#Preview {
    WelcomePage()
        .frame(width: 800, height: 600)
}
