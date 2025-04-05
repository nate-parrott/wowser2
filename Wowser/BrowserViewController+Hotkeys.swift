import AppKit
import Core

extension BrowserViewController {
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
    
    // MARK: - Menu Validation
    
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack):
            return getCurrentWebContent()?.info.canGoBack ?? false
        case #selector(goForward):
            return getCurrentWebContent()?.info.canGoForward ?? false
        case #selector(reload):
            return getCurrentWebContent() != nil
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
        default:
            // For other menu items, use the default validation mechanism
            return true
        }
    }
}
