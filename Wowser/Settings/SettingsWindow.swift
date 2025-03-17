import SwiftUI
import Cocoa

class SettingsWindow: NSWindow {
    // Singleton instance for the settings window
    
    init() {
        // Create the SwiftUI view
        let settingsView = SettingsView()
        
        // Create a hosting controller for the view
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.sizingOptions = []
        
        // Configure window
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
//        self.center()
        self.title = "Preferences"
        self.contentViewController = hostingController
        self.setFrame(CGRect(x: 200, y: 200, width: 500, height: 500), display: false)
//        self.setFrameAutosaveName("WowserPreferences")
        self.isReleasedWhenClosed = false
        
//        // Set toolbar appearance
//        let toolbar = NSToolbar()
//        toolbar.showsBaselineSeparator = false
//        self.toolbar = toolbar
        
    }
    
    // Static method to show the settings window
    static func showSettings() {
        // If window exists, bring it to front
        if let window = NSApp.windows.compactMap({ $0 as? SettingsWindow  }).first {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Otherwise create a new window
        let window = SettingsWindow()
        window.makeKeyAndOrderFront(nil)
    }
}
