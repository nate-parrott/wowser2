import AppKit

public class ArchiveMenuManager: NSObject, NSMenuDelegate {
    let parentMenuItem: NSMenuItem
    let menu: NSMenu
    
    public init(parentMenuItem: NSMenuItem) {
        self.parentMenuItem = parentMenuItem
        self.menu = parentMenuItem.menu!
        super.init()
        self.menu.delegate = self
        // TODO
    }
    
    // TODO: Refresh menu and show bookmarked tabs
}
