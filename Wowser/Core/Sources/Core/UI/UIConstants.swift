import SwiftUI

public enum UIConstants {
    public static var macHeaderHeight: CGFloat = 42
    public static var sidebarWidth: CGFloat = 200
    public static var autoOrgMinTabCount: Int = 5
    public static var mobileKeyboardReopenAfterIdleTime: TimeInterval = 5 * 60
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
