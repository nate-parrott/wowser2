import AppKit

public class ArchiveMenuManager: NSObject, NSMenuDelegate {
    let historyMenu: NSMenu
    let bookmarksMenuItem: NSMenuItem
    
    public init(historyMenu: NSMenu, bookmarksMenuItem: NSMenuItem) {
        self.historyMenu = historyMenu
        self.bookmarksMenuItem = bookmarksMenuItem
        super.init()
    }
    
    // TODO: Refresh menu and show bookmarked tabs
}
