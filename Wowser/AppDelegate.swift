import Core
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate! {
        NSApplication.shared.delegate as? AppDelegate
    }
    
    // MARK: - Actions

    @IBAction func showPreferences(_ sender: Any) {
        SettingsWindow.showSettings()
    }
    
    func createInitialWindowIfNeeded() {
        if windowControllers.count > 0 { return }
        newWindow(nil)
    }
    
    @IBAction func newWindow(_ sender: Any?) {
        let windowController = NSStoryboard.main!.instantiateController(withIdentifier: "BrowserWindowController") as! BrowserWindowController
        windowControllers.append(windowController)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
    
    @IBOutlet private(set) var historyMenu: NSMenu?
    
    // Maps menu items to tab indices for quick tab switching
    var tabSwitchMenuItems = [NSMenuItem: Int]()
    
    // MARK: - Window controllers
    var windowControllers = [BrowserWindowController]()
    
    // MARK: - Lifecycle
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            DefaultsKeys.adblock.rawValue: true,
            DefaultsKeys.autoDarkMode.rawValue: true,
        ])
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        createInitialWindowIfNeeded()
        setupTabSwitchingMenuItems()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            createInitialWindowIfNeeded()
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - Tab Switching Menu Items
    
    private func setupTabSwitchingMenuItems() {
        guard let historyMenu = historyMenu else { return }
        
        // Create hidden menu items for CMD+1 through CMD+9
        for i in 1...9 {
            let menuItem = NSMenuItem(title: "Switch to Tab \(i)", 
                                      action: #selector(BrowserViewController.switchToNthTab(_:)), 
                                     keyEquivalent: "\(i)")
            menuItem.keyEquivalentModifierMask = .command
            menuItem.isHidden = true
            menuItem.allowsKeyEquivalentWhenHidden = true
            
            // Store the mapping of menu item to index (0-based internally)
            tabSwitchMenuItems[menuItem] = i - 1
            
            // Add to the history menu (they'll be hidden)
            historyMenu.addItem(menuItem)
        }
    }
}
