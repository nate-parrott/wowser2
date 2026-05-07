//
//  ViewController.swift
//  Wowser
//
//  Created by Nate Parrott on 3/9/25.
//

import Cocoa
import SwiftUI
import Core
import Combine

class BrowserViewController: NSViewController, NSMenuItemValidation {
    // The window ID for this instance
    private(set) var windowID: ID<WindowState>?
    
    // Store references for cleanup
    private(set) var rootHostingController: NSHostingController<BrowserWindow>?
    
    private let moveBlockingView = MoveBlockingView()
    private let swipeGestureContainer = SwipeGestureContainer()
    private var escapeKeyMonitor: Any?
    private var flagsChangedMonitor: Any?
    private var tabStackCycleActive = false
    private var windowControlsHacker: MacWindowControlsHacker?
    private var subscriptions = Set<AnyCancellable>()
    private(set) var cleanModeButtonStatus = CleanModeButtonStatus.readerUnavail
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Add swipe gesture container and set it as the parent view
        view.addSubview(moveBlockingView)
        view.addSubview(swipeGestureContainer)
        
        // Setup window controls
        if let window = self.view.window {
            windowControlsHacker = MacWindowControlsHacker(window: window)
            windowControlsHacker?.fullscreenChanged = { [weak self] isFullscreen in
                self?.isFullscreen = isFullscreen
            }
            
            // Initialize fullscreen state
            isFullscreen = windowControlsHacker?.isFullscreen ?? false
        }
        
        // Setup swipe gesture observer
        swipeGestureContainer.onSwipeGestureOffsetChanged = { [weak self] offset in
            guard let self = self, let windowID = self.windowID else { return }
            
            BrowserStore.shared.modify { state in
                state.setSwipeGestureOffset(offset, forWindowID: windowID)
//                state.windows[windowID]?.swipeGestureOffset = offset
            }
        }
        
        // Set up escape key monitoring
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  self.view.window?.isKeyWindow == true,
                  event.keyCode == 53 else { // Escape key
                return event
            }

            // Dismiss toast inline
            if let windowID = self.windowID,
               let currentToast = BrowserStore.shared.model.windows[windowID]?.currentToast {
                BrowserStore.shared.modify { state in
                    state.removeToast(id: currentToast.id, in: windowID)
                }
            }

            return event // Let the event continue to propagate
        }

        // Cmd-release commits an in-progress keyboard tab-stack cycle.
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            if self.tabStackCycleActive, !event.modifierFlags.contains(.command) {
                self.endTabStackCycleIfActive()
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBeganTabStackCycle(_:)),
            name: .beginTabStackCycle,
            object: nil
        )
    }

    @objc private func handleBeganTabStackCycle(_ note: Notification) {
        guard let windowID = self.windowID,
              note.userInfo?[tabStackCycleWindowIDKey] as? ID<WindowState> == windowID else { return }
        tabStackCycleActive = true
    }

    private func endTabStackCycleIfActive() {
        guard tabStackCycleActive, let windowID = self.windowID else { return }
        tabStackCycleActive = false
        NotificationCenter.default.post(
            name: .endTabStackCycle,
            object: nil,
            userInfo: [tabStackCycleWindowIDKey: windowID]
        )
    }
    
    // we only expect this to ever be called once per window, by appdelegate
    func setupBrowserViewController(id: ID<WindowState>) {
        self.windowID = id
        
        // Create the SwiftUI hosting view
        if let windowID = self.windowID {
            // Create and configure the hosting view
            let browserWindowView = BrowserWindow(windowID: windowID)
            let hostingController = NSHostingController(rootView: browserWindowView)
            hostingController.sizingOptions = []
            
            // Add the hosting view to our view hierarchy
            addChild(hostingController)
            swipeGestureContainer.addSubview(hostingController.view)
            
            // Store reference for cleanup
            rootHostingController = hostingController
            
            // Set up auto-organize observer
            setupAutoOrganizeObserver()
            
            CleanModeButtonStatus.current(forWindowID: id)
                .sink { [weak self] status in
                    self?.cleanModeButtonStatus = status
                }
                .store(in: &subscriptions)
        }
    }
    
    // Called by BrowserWindowController
    func willClose() {
        rootHostingController?.rootView.unmount = true
    }
    
    var isFullscreen: Bool = false {
        didSet {
            rootHostingController?.rootView.isFullscreen = isFullscreen
        }
    }
    
    // MARK: - Action Methods
    
    // Gets the ID of the current focused pane
    private func getCurrentPaneID() -> ID<WebContent>? {
        guard let windowID = self.windowID else { return nil }
        let state = BrowserStore.shared.model
        
        // Get the current tab and its focused pane
        guard let currentTabID = state.windows[windowID]?.currentTab,
              let tab = state.tabs[currentTabID],
              let paneID = tab.panes.elements.get(tab.focusedPaneIdx)?.id else {
            return nil
        }
        
        return paneID
    }
    
    // Gets the WebContent for the current focused pane
    func getCurrentWebContent() -> WebContent? {
        guard let windowID = self.windowID,
              let paneID = getCurrentPaneID() else { return nil }
        
        return BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID)
    }
    
    /// Edit the URL of the current tab (Cmd+L)
    @IBAction func editCurrentURL(_ sender: Any?) {
        guard let windowID = self.windowID else { return }
        
        // Show search overlay to edit URL
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.searchOverlayActive = true
        }
    }
    
    /// Create a new tab (Cmd+T)
    @IBAction func createNewTab(_ sender: Any?) {
        guard let windowID = self.windowID else { return }
        
        // Create a new tab
        BrowserStore.shared.createTab(
            withURL: nil,  // Start with empty tab
            in: windowID,
            activate: true
        )
        
        // Show search overlay to enter URL
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.searchOverlayActive = true
        }
    }
    
    /// Close the current tab (Cmd+W)
    @IBAction func closeCurrentTab(_ sender: Any?) {
        guard let windowID = self.windowID else { return }
        
        let state = BrowserStore.shared.model
        let currentTabID = state.windows[windowID]?.currentTab
        
        // Close the tab if we found one
        if let tabID = currentTabID {
            // First get all pane IDs for this tab
            let paneIDs = state.tabs[tabID]?.panes.map { $0.id } ?? []
            
            // Close each pane (which will close the tab if it's the last one)
            for paneID in paneIDs {
                BrowserStore.shared.close(webContentId: paneID, removeIfPinned: false)
            }
        } else {
            // No tab active, close window
            view.window?.close()
        }
        
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.searchOverlayActive = false
        }
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        swipeGestureContainer.frame = view.bounds
        moveBlockingView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - UIConstants.macHeaderHeight)
        rootHostingController?.view.frame = swipeGestureContainer.bounds
    }
    
    deinit {
        print("BrowserViewController deinit")
        autoOrgSettingObserver?.cancel()
        autoOrgTicker?.cancel()
        
        // Remove the escape key monitor
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self, name: .beginTabStackCycle, object: nil)
    }
    
    // MARK: - Auto-Organize Tabs

    private func setupAutoOrganizeObserver() {
        // Observe changes to the auto-organize setting in UserDefaults
        autoOrgSettingObserver = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        .map { _ in
            UserDefaults.standard.bool(forKey: DefaultsKeys.autoOrganizeTabs.rawValue)
        }
        .prepend(UserDefaults.standard.bool(forKey: DefaultsKeys.autoOrganizeTabs.rawValue))
        .removeDuplicates()
        .sink { [weak self] enabled in
            self?.autoOrganizeEnabled = enabled
        }
        
        autoOrganizeEnabled = DefaultsKeys.autoOrganizeTabs.boolValue()
    }
    
    private var autoOrgSettingObserver: AnyCancellable?
    // Two triggers: 3600s, or 10 tabs opened
    private var autoOrgTicker: AnyCancellable? // only set up if the setting is on
    private var autoOrgManyTabsOpenedTicker: AnyCancellable? // only set up if the setting is on
    
    private var autoOrganizeEnabled: Bool = false {
        didSet {
            if autoOrganizeEnabled != oldValue {
                if autoOrganizeEnabled {
                    // Create a throttled observer of the BrowserStore that will trigger tab organization once per hour
                    autoOrgTicker = BrowserStore.shared.uiPublisher
                        .throttle(for: .seconds(3600), scheduler: DispatchQueue.main, latest: true)
                        .sink { [weak self] _ in
                            self?.organizeTabs()
                        }
                    
                    if let windowId = self.windowID {
                        autoOrgManyTabsOpenedTicker = BrowserStore.shared.uiPublisher.map { floor(Double($0.windows[windowId]?.tabsOpened ?? 0) / 10) }
                            .removeDuplicates()
                            .dropFirst()
                            .sink(receiveValue: { [weak self] _ in
                                self?.organizeTabs()
                            })
                    }
                } else {
                    // Tear down store observation
                    autoOrgTicker?.cancel()
                    autoOrgTicker = nil
                    
                    autoOrgManyTabsOpenedTicker?.cancel()
                    autoOrgManyTabsOpenedTicker = nil
                }
            }
        }
    }
}

// MARK: - SwiftUI Window Content
private struct BrowserWindowWrapper: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        BrowserWindow(windowID: windowID)
    }
}

private class MoveBlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
