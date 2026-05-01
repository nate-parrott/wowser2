import Core
import Cocoa
import CoreServices
import Carbon
import Combine

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
    
    private var windowIDs: Set<ID<WindowState>> = .init() {
        didSet {
            let addedWindowIDs = windowIDs.filter({ !oldValue.contains($0) })
            let removedWindowIDs = oldValue.filter({ !windowIDs.contains($0) })
            for id in addedWindowIDs {
                let windowController = NSStoryboard.main!.instantiateController(withIdentifier: "BrowserWindowController") as! BrowserWindowController
                windowControllers.append(windowController)
                windowController.browserViewController?.setupBrowserViewController(id: id)
                windowController.window?.makeKeyAndOrderFront(nil)
            }
            for id in removedWindowIDs {
                if let controller = windowControllers.first(where: { $0.browserViewController?.windowID == id }) {
                    controller.window?.close()
                }
            }
        }
    }
    
    @IBAction func newWindow(_ sender: Any?) {
        BrowserStore.shared.modify { state in
            let id = state.newWindow().id
            state.openTab(url: URL(string: "https://google.com")!, activate: true, windowID: id)
        }
//        let windowController = NSStoryboard.main!.instantiateController(withIdentifier: "BrowserWindowController") as! BrowserWindowController
//        windowControllers.append(windowController)
//        windowController.window?.makeKeyAndOrderFront(nil)
    }
    
    @IBAction func becomeDefaultBrowser(_ sender: Any?) {
        // Register as the default handler for http and https URLs
        LSSetDefaultHandlerForURLScheme("http" as CFString, Bundle.main.bundleIdentifier! as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, Bundle.main.bundleIdentifier! as CFString)
        
//        // Show toast notification
//        if let activeWindowID = activeWindowId{
//            BrowserStore.shared.modify { state in
//                state.addToast(message: "Wowser is now your default browser", icon: "globe", in: activeWindowID)
//            }
//        }
    }
    
    // MARK: - Outlets
    
    @IBOutlet private(set) var historyMenu: NSMenu?    
    @IBOutlet private(set) var bookmarksMenuItem: NSMenuItem?
    private var archiveMenuManager: ArchiveMenuManager?

    // Maps menu items to tab indices for quick tab switching
    var tabSwitchMenuItems = [NSMenuItem: Int]()
    
    // MARK: - Window controllers
    var windowControllers = [BrowserWindowController]()
    var activeWindowId: ID<WindowState>? {
        if let win = NSApp.mainWindow?.delegate as? BrowserWindowController {
            return win.browserViewController?.windowID
        }
        if let lastWin = NSApp.windows.compactMap({ ($0.delegate as? BrowserWindowController)?.browserViewController?.windowID }).last {
            return lastWin
        }
        return nil
    }
    
    // MARK: - Lifecycle
    
    private var subscriptions = Set<AnyCancellable>()
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            DefaultsKeys.adblock.rawValue: true,
            DefaultsKeys.cookieBannerBlock.rawValue: true,
            DefaultsKeys.autoDarkMode.rawValue: true,
            DefaultsKeys.animateNewTabs.rawValue: true,
            DefaultsKeys.searchEngine.rawValue: SearchEngine.google.rawValue,
            DefaultsKeys.Chatbot.rawValue: Chatbot.claude.rawValue,
            DefaultsKeys.preserveWindowsAcrossRestarts.rawValue: true,
            DefaultsKeys.cleanModeForRecipes.rawValue: true,
            DefaultsKeys.autoOrganizeTabs.rawValue: true,
            DefaultsKeys.enableGoDirectQueries.rawValue: false,
            DefaultsKeys.homepagePrompt.rawValue: "Create a fun, engaging, interesting homepage with the latest news.",
            DefaultsKeys.llmChoice.rawValue: LLMChoice.openai_gpt4o_mini.rawValue,
            DefaultsKeys.openAIKey.rawValue: "[REMOVED-OPENAI-KEY]"
        ])
        
        #if os(macOS)
        UserDefaults.standard.setValue(0, forKey: "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached")
        #endif
        
        GlobalHacks.hacks = MacHacks()
        
        Preheat.preheat()
        
        archiveMenuManager = ArchiveMenuManager(bookmarksMenuItem: bookmarksMenuItem!, openURL: { [weak self] url in
            self?.openURL(url)
        })
        
        // Register for Apple Events to handle URLs
        let appleEventManager = NSAppleEventManager.shared()
        appleEventManager.setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        BrowserStore.shared.publisher.map { $0.windows.keys }.removeDuplicates()
            .sink { [weak self] ids in
                self?.windowIDs = Set(ids)
            }.store(in: &subscriptions)
        createInitialWindowIfNeeded()
        setupTabSwitchingMenuItems()
        
        // show welcome?
        let appVer = 1
        if appVer > DefaultsKeys.lastAutoArchiveDate.intValue() {
            DefaultsKeys.lastAutoArchiveDate.setInt(appVer)
            openURL(URL(string: "https://www.notion.so/nate223/Welcome-to-Tangerine-1f48cbaf64db80eeb4c3f443a4f85c82?pvs=4")!)
        }
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
        // Unregister Apple Event handler
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - URL Handling
    
    // Handle URLs passed to the application
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openURL(url)
        }
    }
    
    // Handle Apple Event for getURL (kAEGetURL)
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        // Extract the URL from the event
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        // Open the URL in our browser
        openURL(url)
    }
    
    // Handles URLs directly
    func openURL(_ url: URL) {
        // Use BrowserStore's openTab method to open the URL
        BrowserStore.shared.modify { state in
            state.openTab(url: url, activate: true)
        }
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
