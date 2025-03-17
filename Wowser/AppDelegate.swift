import Core
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBAction func showPreferences(_ sender: Any) {
        SettingsWindow.showSettings()
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            DefaultsKeys.adblock.rawValue: true,
            DefaultsKeys.autoDarkMode.rawValue: true,
        ])
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
