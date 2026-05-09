import SwiftUI

// MARK: - Window ID Environment Key
private struct WindowIDKey: EnvironmentKey {
    static let defaultValue: ID<WindowState>? = nil
}

// MARK: - Profile ID Environment Key
private struct ProfileIDKey: EnvironmentKey {
    static let defaultValue: ID<Profile>? = nil
}

// MARK: - Fullscreen Environment Key
private struct IsFullscreenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

// MARK: - Environment Extensions
public extension EnvironmentValues {
    var windowID: ID<WindowState>? {
        get { self[WindowIDKey.self] }
        set { self[WindowIDKey.self] = newValue }
    }

    var profileID: ID<Profile>? {
        get { self[ProfileIDKey.self] }
        set { self[ProfileIDKey.self] = newValue }
    }

    var isFullscreen: Bool {
        get { self[IsFullscreenKey.self] }
        set { self[IsFullscreenKey.self] = newValue }
    }
}

// MARK: - Browser Context Helper
public extension View {
    /// Convenience method to set both window ID and profile ID environment variables
    func withBrowserContext(
        windowID: ID<WindowState>,
        profileID: ID<Profile>
    ) -> some View {
        self
            .environment(\.windowID, windowID)
            .environment(\.profileID, profileID)
    }
}
