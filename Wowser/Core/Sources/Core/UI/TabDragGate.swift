import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Notification.Name {
    /// Posted when the user mouseDowns inside the sidebar — arms split-drop
    /// targets so a tab drag can be received by panes. Global, not scoped per window.
    public static let showTabDropTargets = Notification.Name("showTabDropTargets")
    /// Posted on mouseUp anywhere — disarms split-drop targets.
    public static let hideTabDropTargets = Notification.Name("hideTabDropTargets")
}

/// Conformed-to by the AppKit window subclass so the SwiftUI Sidebar (in Core)
/// can publish its frame back to the window. The window's sendEvent override
/// reads this to decide whether a mouseDown was over the sidebar.
///
/// Frame is in the window's SwiftUI-named "BrowserWindowRoot" coordinate
/// space (top-left origin), so callers must convert NSEvent locations
/// accordingly before comparing.
public protocol SidebarFrameHostingWindow: AnyObject {
    var sidebarFrameInWindow: CGRect? { get set }
}
