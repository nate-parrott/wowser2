#if os(macOS)
import AppKit
import CoreServices

/// Making Wowser the system's default web browser (the app menu's "Make
/// Default Browser" and onboarding).
public enum DefaultBrowser {
    /// Registers this app for http/https. macOS asks the user to confirm.
    public static func makeDefault() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("http" as CFString, bundleID as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, bundleID as CFString)
    }

    /// Whether https links currently open in this app. Asks LaunchServices, so
    /// call it off the main thread / from a task, never from a view's body.
    public static func isDefault() -> Bool {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
#endif
