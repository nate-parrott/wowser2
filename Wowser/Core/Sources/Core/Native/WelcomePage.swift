import SwiftUI

/// Onboarding page (`NativePageKey.welcome`), opened in a tab on first launch
/// and from the command bar / Settings. See `OnboardingFlow`.
struct WelcomePage: View {
    /// The tab's pane; closed when onboarding finishes.
    var webContentID: ID<WebContent>?

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
        .background(Color("Background", bundle: .module))
    }
}

#Preview {
    WelcomePage()
        .frame(width: 800, height: 600)
}
