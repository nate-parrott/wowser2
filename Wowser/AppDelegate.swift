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
}
