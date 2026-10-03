import SwiftUI

/// Onboarding page (`NativePageKey.welcome`), opened in a tab on first launch.
/// Placeholder for now.
struct WelcomePage: View {
    var body: some View {
        Text("Welcome")
            .font(.system(size: 34, weight: .bold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("Background", bundle: .module))
    }
}

#Preview {
    WelcomePage()
        .frame(width: 800, height: 600)
}
