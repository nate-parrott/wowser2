//
//  ViewController.swift
//  Wowser
//
//  Created by Nate Parrott on 3/9/25.
//

import Cocoa
import SwiftUI
import Core

class ViewController: NSViewController {
    // The window ID for this instance
    private var windowID: ID<WindowState>?
    
    // Store references for cleanup
    private var rootHostingView: NSView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupBrowserWindow()
    }
    
    deinit {
        // When deallocating, clean up by removing the window from the store
        cleanupWindow()
    }
    
    private func setupBrowserWindow() {
        // Create a new window ID and initialize it in the BrowserStore
        let newWindowID = ID<WindowState>.assign()
        self.windowID = newWindowID
        
        BrowserStore.shared.modify { state in
            let window = state.newWindow()
            self.windowID = window.id
        }
        
        // Create a default tab using the helper method directly on BrowserStore
        if let windowID = windowID {
            BrowserStore.shared.createTab(
                withURL: URL(string: "https://www.google.com"),
                in: windowID,
                activate: true
            )
        }
        
        // Create the SwiftUI hosting view
        if let windowID = self.windowID {
            setupHostingView(windowID: windowID)
        }
    }
    
    private func setupHostingView(windowID: ID<WindowState>) {
        // Create and configure the hosting view
        let browserWindowView = BrowserWindow(windowID: windowID)
        let hostingController = NSHostingController(rootView: browserWindowView)
        hostingController.sizingOptions = []
        
        // Add the hosting view to our view hierarchy
        addChild(hostingController)
        view.addSubview(hostingController.view)
        
        // Configure constraints
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Store reference for cleanup
        rootHostingView = hostingController.view
    }
    
    private func cleanupWindow() {
        guard let windowID = self.windowID else { return }
        
        // Use the helper method to close all contents in this window
        BrowserStore.shared.closeAllContentsInWindow(windowID: windowID, removeWindow: true)
    }
    
    // Handle window close event
    override func viewDidDisappear() {
        super.viewDidDisappear()
        cleanupWindow()
    }
    
    // MARK: - Action Methods
    
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
        
        Task {
            await BrowserStore.shared.readAsync { state in
                let currentTabID = state.windows[windowID]?.currentTab
                
                // Close the tab if we found one
                if let tabID = currentTabID {
                    // First get all pane IDs for this tab
                    let paneIDs = state.tabs[tabID]?.panes.map { $0.id } ?? []
                    
                    // Return to main queue to close them
                    DispatchQueue.main.async {
                        // Close each pane (which will close the tab if it's the last one)
                        for paneID in paneIDs {
                            BrowserStore.shared.close(webContentId: paneID, removeIfPinned: true)
                        }
                    }
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
