//
//  ViewController.swift
//  Wowser
//
//  Created by Nate Parrott on 3/9/25.
//

import Cocoa
import SwiftUI
import Core

class BrowserViewController: NSViewController, NSMenuItemValidation {
    // The window ID for this instance
    private(set) var windowID: ID<WindowState>?
    
    // Store references for cleanup
    private(set) var rootHostingController: NSHostingController<BrowserWindow>?
    
    private let moveBlockingView = MoveBlockingView()
    private let swipeGestureContainer = SwipeGestureContainer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Add swipe gesture container and set it as the parent view
        view.addSubview(moveBlockingView)
        view.addSubview(swipeGestureContainer)
        
        // Setup swipe gesture observer
        swipeGestureContainer.onSwipeGestureOffsetChanged = { [weak self] offset in
            guard let self = self, let windowID = self.windowID else { return }
            
            BrowserStore.shared.modify { state in
                state.windows[windowID]?.swipeGestureOffset = offset
            }
        }
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
        }
    }
    
    // Called by BrowserWindowController
    func willClose() {
        rootHostingController?.rootView.unmount = true
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
    }
    
    override func viewWillLayout() {
        super.viewWillLayout()
        swipeGestureContainer.frame = view.bounds
        moveBlockingView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - UIConstants.macHeaderHeight)
        rootHostingController?.view.frame = swipeGestureContainer.bounds
    }
    
    deinit {
        print("BrowserViewController deinit")
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
