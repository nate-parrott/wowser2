import Foundation

public enum AppPaths {
    /// Application Support, or `$WOWSER_DATA_DIR` when set: lets two copies
    /// of the app run side by side with their own ephemeral data (see
    /// scripts/sync_test). Everything that persists user data resolves its
    /// directory from here.
    public static let applicationSupport: URL = {
        if let dir = ProcessInfo.processInfo.environment["WOWSER_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }()

    /// `$WOWSER_EPHEMERAL_WEBSITE_DATA=1`: cookies/caches live in memory
    /// instead of WebKit's per-space stores (test instances).
    public static let ephemeralWebsiteData = ProcessInfo.processInfo.environment["WOWSER_EPHEMERAL_WEBSITE_DATA"] == "1"
}
