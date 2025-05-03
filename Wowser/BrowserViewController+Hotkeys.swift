import AppKit
import Core

extension BrowserViewController {
    @IBAction func copyCurrentURL(_ sender: Any?) {
        if let urlString = getCurrentWebContent()?.info.url?.absoluteString,
           let windowID = self.windowID {
            // Copy to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urlString, forType: .string)
            
            // Show toast notification
            BrowserStore.shared.modify { state in
                state.addToast(message: "Copied Link", icon: "doc.on.clipboard", in: windowID)
            }
        }
    }
    
    @IBAction func goBack(_ sender: Any?) {
        getCurrentWebContent()?.goBack()
    }
    
    @IBAction func goForward(_ sender: Any?) {
        getCurrentWebContent()?.goForward()
    }
    
    @IBAction func reload(_ sender: Any?) {
        getCurrentWebContent()?.reload()
    }
    
    @IBAction func goToPreviousTab(_ sender: Any?) {
        guard let windowID = self.windowID else { return }
        
        // Find the most recently active tab that's not the current one
        if let previousTabID = BrowserStore.shared.model.findPreviouslyActiveTab(inWindow: windowID) {
            // Activate that tab
            BrowserStore.shared.modify { state in
                state.activate(tabId: previousTabID, in: windowID)
            }
        }
    }
    
    /// Helper method to switch tabs by shifting the index in the visible tabs array
    /// - Parameter delta: The amount to shift the index (negative to go up, positive to go down)
    private func shiftVisibleTabIndex(by delta: Int) {
        guard let windowID = self.windowID else { return }
        let state = BrowserStore.shared.model
        
        // Get all tabs in visible order
        let visibleTabs = state.tabsInVisibleOrder(inWindow: windowID)
        guard !visibleTabs.isEmpty,
              let currentTabID = state.windows[windowID]?.currentTab else {
            return
        }
        
        // Find current tab index
        if let currentIndex = visibleTabs.firstIndex(of: currentTabID) {
            // Calculate new index with wrapping
            let tabCount = visibleTabs.count
            let newIndex = (currentIndex + delta + tabCount) % tabCount
            let tabToActivate = visibleTabs[newIndex]
            
            // Activate the tab
            BrowserStore.shared.modify { state in
                state.activate(tabId: tabToActivate, in: windowID)
            }
        }
    }
    
    @IBAction func switchToTabAbove(_ sender: Any?) {
        shiftVisibleTabIndex(by: -1) // Move up by one position (or wrap to bottom)
    }
    
    @IBAction func switchToTabBelow(_ sender: Any?) {
        shiftVisibleTabIndex(by: 1) // Move down by one position (or wrap to top)
    }
    
    /// Switch to a specific tab by its index in the visible tabs array
    /// - Parameter index: Zero-based index of the tab to activate (0 for first tab, 1 for second, etc.)
    func switchToTabByIndex(_ index: Int) {
        guard let windowID = self.windowID else { return }
        let state = BrowserStore.shared.model
        
        // Get tabs in visible order
        let visibleTabs = state.tabsInVisibleOrder(inWindow: windowID)
        
        // Validate the index is within bounds
        guard index >= 0, index < visibleTabs.count else { return }
        
        // Get the tab to activate
        let tabToActivate = visibleTabs[index]
        
        // Activate the tab
        BrowserStore.shared.modify { state in
            state.activate(tabId: tabToActivate, in: windowID)
        }
    }
    
    @objc func switchToNthTab(_ sender: NSMenuItem) {
        guard let index = AppDelegate.shared.tabSwitchMenuItems[sender] else { return }
        
        // Forward to the current key window's browser view controller
        if let window = NSApp.keyWindow,
           let windowController = window.windowController as? BrowserWindowController,
           let browserViewController = windowController.contentViewController as? BrowserViewController {
            browserViewController.switchToTabByIndex(index)
        }
    }
    
    @IBAction func toggleBookmark(_ sender: NSMenuItem) {
        if let webContent = getCurrentWebContent(),
           let url = webContent.info.url,
           let windowID = self.windowID {
            Task {
                let wasBookmarked = await ArchiveStore.shared.isItemBookmarked(url: url)
                ArchiveStore.shared.toggleBookmark(url: url, title: webContent.info.title)
                
                // Show toast notification
                BrowserStore.shared.modify { state in
                    // Check if the URL is bookmarked after toggle
                    let isBookmarked = !wasBookmarked
                    let message = isBookmarked ? "Bookmark added" : "Bookmark removed"
                    let icon = isBookmarked ? "bookmark.fill" : "bookmark.slash"
                    state.addToast(message: message, icon: icon, in: windowID)
                }
            }
        }
    }
    
    @IBAction func clearAllTabs(_ sender: NSMenuItem) {
        if let windowID {
            BrowserStore.shared.clearAllTabs(in: windowID)
        }
    }
    
    @IBAction func organizeTabs(_ sender: NSMenuItem? = nil) {
        if let windowID {
            Task {
                await BrowserStore.shared.autoOrganizeTabs(in: windowID)
            }
        }
    }
    
    /// Save the current page (Save As)
    @IBAction func saveCurrentPage(_ sender: Any?) {
        guard let webContent = getCurrentWebContent(),
              let url = webContent.info.url,
              let windowID = self.windowID else { return }
        
        // Create a URL request for the current page
        let request = URLRequest(url: url)
        
        // Create a download task
        webContent.webview.downloadUsingRequest(request, windowID: windowID)
    }
    
    @IBAction func zoomIn(_ sender: Any?) {
        getCurrentWebContent()?.zoomIn()
    }
    
    @IBAction func zoomOut(_ sender: Any?) {
        getCurrentWebContent()?.zoomOut()
    }
    
    @IBAction func resetZoom(_ sender: Any?) {
        getCurrentWebContent()?.resetZoom()
    }
    
    // MARK: - Menu Validation
    
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack):
            return getCurrentWebContent()?.info.canGoBack ?? false
        case #selector(goForward):
            return getCurrentWebContent()?.info.canGoForward ?? false
        case #selector(reload), #selector(copyCurrentURL), #selector(zoomIn), #selector(zoomOut), #selector(resetZoom):
            return getCurrentWebContent() != nil
        case #selector(saveCurrentPage(_:)):
            // Only enable Save As menu item if there's a valid URL in the current web content
            if let webContent = getCurrentWebContent(), webContent.info.url != nil {
                return true
            }
            return false
        case #selector(goToPreviousTab):
            // Only enable if there's a window ID and there's a previous tab to go to
            if let windowID = self.windowID {
                return BrowserStore.shared.model.findPreviouslyActiveTab(inWindow: windowID) != nil
            }
            return false
        case #selector(switchToTabAbove), #selector(switchToTabBelow):
            // Enable if there's more than one tab in the visible order
            if let windowID = self.windowID {
                let tabCount = BrowserStore.shared.model.tabsInVisibleOrder(inWindow: windowID).count
                return tabCount > 1
            }
            return false
        case #selector(BrowserViewController.switchToNthTab(_:)):
            // For tab index switching shortcuts (CMD+1...9)
            if let windowID = self.windowID, 
               let appDelegate = AppDelegate.shared,
               let index = appDelegate.tabSwitchMenuItems[menuItem] {
                // Enable only if this tab index exists
                let visibleTabs = BrowserStore.shared.model.tabsInVisibleOrder(inWindow: windowID)
                return index < visibleTabs.count
            }
            return false
        default:
            // For other menu items, use the default validation mechanism
            return true
        }
    }
}
