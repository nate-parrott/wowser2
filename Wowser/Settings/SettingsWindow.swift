import SwiftUI
import Core
import Cocoa

class SettingsWindow: NSWindow {
    // Singleton instance for the settings window
    
    init(initialTab: SettingsTab = .general) {
        // Create the SwiftUI view
        let settingsView = SettingsView(initialTab: initialTab)
        
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
        self.setFrame(CGRect(x: 200, y: 200, width: 820, height: 560), display: false)
//        self.setFrameAutosaveName("WowserPreferences")
        self.isReleasedWhenClosed = false
        
//        // Set toolbar appearance
//        let toolbar = NSToolbar()
//        toolbar.showsBaselineSeparator = false
//        self.toolbar = toolbar
        
    }
    
    // Static method to show the settings window
    static func showSettings(tab: SettingsTab? = nil) {
        // If window exists, bring it to front
        if let window = NSApp.windows.compactMap({ $0 as? SettingsWindow  }).first {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let tab { tab.open() } // SettingsView listens for .showSettings and switches tabs
            return
        }
        
        // Otherwise create a new window
        let window = SettingsWindow(initialTab: tab ?? .general)
        window.makeKeyAndOrderFront(nil)
    }

    /// Core posts `.showSettings` (e.g. from the toolbar's "Customize Toolbar…" menu item).
    static func observeShowSettingsRequests() {
        NotificationCenter.default.addObserver(forName: .showSettings, object: nil, queue: .main) { note in
            // Only create/raise the window here; if it already exists SettingsView handles the tab switch itself.
            if NSApp.windows.contains(where: { $0 is SettingsWindow }) {
                NSApp.windows.compactMap({ $0 as? SettingsWindow }).first?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                showSettings(tab: SettingsTab.from(note))
            }
        }
    }
}
