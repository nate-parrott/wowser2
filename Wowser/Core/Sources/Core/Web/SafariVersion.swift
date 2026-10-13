import Foundation
#if os(macOS)
import AppKit
#endif

/// The installed Safari's version (e.g. "27.0"), which the desktop user agent
/// claims. Sites gate WebKit workarounds on it: Google Docs, on Safari < 26.4,
/// multiplies its canvas resolution by `outerWidth / innerWidth` to guess page
/// zoom, so a stale version can render Docs blurry (or needlessly huge).
///
/// Reading Safari's Info.plist is disk I/O, so the value is cached in defaults
/// and refreshed off the main thread at launch; webviews read the cache.
enum SafariVersion {
    /// Used until the first refresh lands. At least 26.4 so Docs skips its
    /// zoom heuristic.
    static let fallback = "26.4"

    static var current: String {
        DefaultsKeys.installedSafariVersion.stringValue(defaultValue: fallback)
    }

    static func refreshInBackground() {
        #if os(macOS)
        DispatchQueue.global(qos: .utility).async {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
                ?? URL(fileURLWithPath: "/Applications/Safari.app")
            guard let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                  !version.isEmpty,
                  version != DefaultsKeys.installedSafariVersion.stringValue() else { return }
            DefaultsKeys.installedSafariVersion.setString(version)
        }
        #endif
    }
}
