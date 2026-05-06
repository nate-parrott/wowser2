import Foundation

/// Returns true if this is a "production" build of the app.
///
/// Two ways to be prod:
/// 1. A Release build (DEBUG flag not set), OR
/// 2. The `.app` bundle name contains "PROD" (case-insensitive). This lets us
///    promote a debug build to prod just by renaming the .app in Finder.
public func isProd() -> Bool {
    #if DEBUG
    let isReleaseBuild = false
    #else
    let isReleaseBuild = true
    #endif
    let appName = Bundle.main.bundleURL.lastPathComponent
    let bundleHasProd = appName.uppercased().contains("PROD")
    return isReleaseBuild || bundleHasProd
}

/// Suffix to apply to data directories to keep prod/dev state separate.
/// Empty string for prod (so production data lives at the canonical path
/// the app has always used), `-dev` for non-prod.
public func dataDirSuffix() -> String {
    isProd() ? "" : "-dev"
}

public enum VSCodeConfig {
    /// Fixed loopback port for `code serve-web`. Different per build flavor so a
    /// dev and prod build can run side-by-side. Picked from the IANA dynamic
    /// range; uncommon enough to not collide with anything typical.
    public static var serveWebPort: Int {
        isProd() ? 53683 : 53684
    }

    public static var serveWebHost: String { "127.0.0.1" }

    /// Base URL where the VS Code serve-web instance is mounted (no trailing slash on host).
    public static var serveWebBaseURL: URL {
        URL(string: "http://\(serveWebHost):\(serveWebPort)/")!
    }

    /// True if `url` points at our locally mounted VS Code serve-web server.
    /// Lets callers detect VS Code tabs from the URL alone.
    public static func isServeWebURL(_ url: URL) -> Bool {
        guard let host = url.host, let port = url.port else { return false }
        return host == serveWebHost && port == serveWebPort
    }
}
