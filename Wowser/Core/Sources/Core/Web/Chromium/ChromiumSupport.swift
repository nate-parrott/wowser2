import Foundation

#if canImport(CefKit) && os(macOS)
import AppKit
import CefKit
import CCefAppKit
#endif

/// Entry points for the optional CEF (Chromium) engine. All of this compiles
/// to no-ops in WebKit-only builds (see the `.cef-enabled` flag in
/// Core/Package.swift), so callers never need their own `#if` guards.
public enum ChromiumSupport {
    /// True when this build includes the CEF/Chromium engine.
    public static var isAvailable: Bool {
        #if canImport(CefKit) && os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Must run at process start, before anything touches `NSApp` (i.e. before
    /// `NSApplicationMain`). CEF requires the NSApplication instance to conform
    /// to its CrAppControlProtocol from the very first event, so CEF-capable
    /// builds install `CEFApplication` even if no Chromium tab is ever opened.
    /// No-op in WebKit-only builds and on iOS.
    public static func installApplicationClassIfAvailable() {
        #if canImport(CefKit) && os(macOS)
        CEFApplication.install()
        #endif
    }

    #if canImport(CefKit) && os(macOS)
    /// Lazily brings up the CEF runtime (loads the embedded framework, runs
    /// `cef_initialize`, starts the external message pump). Called on first
    /// Chromium tab creation. Returns false when initialization fails — most
    /// commonly because the CEF framework + helper apps aren't embedded in the
    /// app bundle (see scripts/cef/README.md).
    @MainActor
    @discardableResult
    static func ensureRuntimeInitialized() -> Bool {
        if CefRuntime.shared.isInitialized { return true }
        var config = CefConfiguration.default
        config.userAgentProduct = "Wowser"
        do {
            try CefRuntime.shared.initialize(configuration: config)
            return true
        } catch {
            softAssert("CEF runtime failed to initialize (is the CEF framework embedded in the app bundle? see scripts/cef/README.md): \(error)")
            return false
        }
    }
    #endif
}
