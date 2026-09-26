import SwiftUI

public enum UIConstants {
    public static var macHeaderHeight: CGFloat = 42
    public static let defaultSidebarWidth: CGFloat = 200
    public static let minSidebarWidth: CGFloat = 160
    public static let maxSidebarWidth: CGFloat = 420
    /// Live sidebar width, persisted via `DefaultsKeys.sidebarWidth`. Views
    /// that must re-layout when it changes observe that key with @AppStorage;
    /// non-view code reads this directly.
    public static var sidebarWidth: CGFloat = clampSidebarWidth(CGFloat(DefaultsKeys.sidebarWidth.doubleValue(defaultValue: Double(defaultSidebarWidth))))

    public static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    public static func setSidebarWidth(_ width: CGFloat) {
        let clamped = clampSidebarWidth(width)
        sidebarWidth = clamped
        DefaultsKeys.sidebarWidth.setDouble(Double(clamped))
    }
    public static var autoOrgMinTabCount: Int = 5
    public static var mobileKeyboardReopenAfterIdleTime: TimeInterval = 5 * 60
    public static var macTabHeight: CGFloat = 34
}

func isMobile() -> Bool {
    #if os(iOS)
    // TODO: return false for ipad
    return true
    #else
    return false
    #endif
}

func isDesktop() -> Bool {
    !isMobile()
}
