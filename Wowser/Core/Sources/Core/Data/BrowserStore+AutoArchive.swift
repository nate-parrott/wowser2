import Foundation
#if os(macOS)
import AppKit
#endif

// Control for auto-archive logging
private let AUTO_ARCHIVE_LOGGING_ENABLED = false

// Helper function for auto-archive logging
private func autoArchiveLog(_ message: String) {
    if AUTO_ARCHIVE_LOGGING_ENABLED {
        print("😴 [AutoArchive] \(message)")
    }
}

// Extension to identify tabs that should be auto-archived
extension BrowserState {
    /// Returns a list of tabs that meet the auto-archive criteria
    /// - Parameters:
    ///   - olderThan: The cutoff date for tab inactivity (e.g., 4 hours ago)
    ///   - beforeBoundary: The day boundary (5am) before which tabs must have been accessed
    /// - Returns: Array of tuples containing tab ID, pane ID, URL, and title for tabs to archive
    func tabsToAutoArchive(olderThan: Date, beforeBoundary: Date) -> [(tabID: ID<Tab>, paneID: ID<WebContent>, url: URL, title: String?)] {
        autoArchiveLog("Searching for tabs to archive...")
        autoArchiveLog("Criteria: older than \(olderThan), before boundary \(beforeBoundary)")
        
        var tabsToArchive: [(tabID: ID<Tab>, paneID: ID<WebContent>, url: URL, title: String?)] = []
        
        // Examine each window
        for windowID in windows.keys {
            guard let window = windows[windowID] else { continue }
            
            // Get list of tabs to process
            let tabsToProcess = window.tabs
            autoArchiveLog("Window \(windowID.raw) has \(tabsToProcess.count) tabs to check")
            
            for tabID in tabsToProcess {
                guard let tab = tabs[tabID] else {
//                    autoArchiveLog("Tab \(tabID.raw) not found in state")
                    continue
                }
                
                let isPinned = self.isPinned(tabId: tabID)
                if isPinned {
                    autoArchiveLog("Tab \(tabID.raw) is pinned - skipping")
                    continue
                }
                
                guard let pane = tab.panes.first else {
                    autoArchiveLog("Tab \(tabID.raw) has no panes - skipping")
                    continue
                }
                
                guard let url = pane.info.url else {
                    autoArchiveLog("Tab \(tabID.raw) has no URL - skipping")
                    continue
                }
                
                // Skip if tab is currently active
                if window.currentTab == tabID {
                    autoArchiveLog("Tab \(tabID.raw) is currently active - skipping")
                    continue
                }
                
                // Check if tab meets archiving criteria
                autoArchiveLog("Tab \(tabID.raw) last accessed: \(tab.lastAccessed)")
                
                // 1. Last active > cutoff time
                let olderThanCutoff = tab.lastAccessed < olderThan
                if !olderThanCutoff {
                    autoArchiveLog("Tab \(tabID.raw) was active recently - skipping")
                    continue
                }
                
                // 2. Last active before the day boundary (5am)
                let beforeDayBoundary = tab.lastAccessed < beforeBoundary
                if !beforeDayBoundary {
                    autoArchiveLog("Tab \(tabID.raw) was active after day boundary - skipping")
                    continue
                }
                
                autoArchiveLog("Tab \(tabID.raw) [\(pane.info.title ?? url.absoluteString)] is eligible for archiving!")
                tabsToArchive.append((tabID: tabID, paneID: pane.id, url: url, title: pane.info.title))
            }
        }
        
        autoArchiveLog("Found \(tabsToArchive.count) tabs to archive")
        return tabsToArchive
    }
}

extension BrowserStore {
    /// Sets up auto-archiving to run when system wakes from sleep or app foregrounds
    public func setupAutoArchiving() {
        autoArchiveLog("Setting up auto-archiving observers")
        #if os(macOS)
        // Set up notification observers for system wake and app foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemWakeOrForeground),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemWakeOrForeground),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        autoArchiveLog("Observers registered for wake and foreground events")
        #else
        // TODO: for ios, handle foreground
        autoArchiveLog("iOS observers not yet implemented")
        #endif
    }
    
    @objc private func handleSystemWakeOrForeground() {
        autoArchiveLog("System woke or app came to foreground, checking if archiving needed")
        autoArchiveIfNecessary()
    }
    
    /// Auto-archives tabs if conditions are met:
    /// - Auto-archive is enabled in settings
    /// - Tab was last active more than 4 hours ago
    /// - Tab was last active before today's 5am boundary
    private func autoArchiveIfNecessary() {
        // Check if auto-archive feature is enabled
        if !DefaultsKeys.autoArchiveTabs.boolValue() {
            autoArchiveLog("Auto-archive is disabled in settings, skipping")
            return
        }
        autoArchiveLog("Auto-archive is enabled, proceeding with checks")
        
        // Get the current date and time
        let now = Date()
        autoArchiveLog("Current time: \(now)")
        
        // Calculate today's 5am boundary
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 5
        components.minute = 0
        components.second = 0
        
        guard let todayBoundary = calendar.date(from: components) else { 
            autoArchiveLog("Failed to calculate day boundary")
            return 
        }
        
        // If current time is before 5am, use yesterday's 5am as the boundary
        let dayBoundary = now < todayBoundary ? 
            calendar.date(byAdding: .day, value: -1, to: todayBoundary)! : 
            todayBoundary
        
        autoArchiveLog("Using day boundary: \(dayBoundary)")
        
        // Check if we already ran auto-archive today
        if let lastArchiveDate = DefaultsKeys.lastAutoArchiveDate.dateValue() {
            autoArchiveLog("Last archive date: \(lastArchiveDate)")
            // If the last archive was after the day boundary, don't archive again
            if lastArchiveDate > dayBoundary {
                autoArchiveLog("Already archived tabs today, skipping")
                return
            }
        } else {
            autoArchiveLog("No previous archive date found")
        }
        
        // The minimum time a tab should be inactive to be archived (4 hours ago)
        let fourHoursAgo = now.addingTimeInterval(-4 * 60 * 60)
        autoArchiveLog("Four hours ago: \(fourHoursAgo)")
        
        // Get the list of tabs to auto-archive
        let tabsToArchive = self.model.tabsToAutoArchive(olderThan: fourHoursAgo, beforeBoundary: dayBoundary)
        
        if tabsToArchive.isEmpty {
            autoArchiveLog("No tabs to archive")
            return
        }
        
        // Process each tab for archiving
        var didArchive = false
        autoArchiveLog("Beginning to archive \(tabsToArchive.count) tabs")
        
        for (tabID, paneID, url, title) in tabsToArchive {
            autoArchiveLog("Archiving tab \(tabID.raw) with URL: \(url.absoluteString)")
            
            // Create archive item
            let archiveItem = ArchiveItem(
                added: Date(),
                url: url,
                historyKey: url.historyKey,
                title: title,
                kind: .autoArchivedTab
            )
            
            // Add to archive
            Queue.archiveQueue.run {
                autoArchiveLog("Adding tab \(tabID.raw) to archive store")
                ArchiveStore.shared.add(item: archiveItem)
            }
            
            // Close the tab (outside the modify block)
            autoArchiveLog("Closing tab \(tabID.raw) (pane: \(paneID.raw))")
            close(webContentId: paneID, removeIfPinned: false)
            didArchive = true
        }
        
        // If we archived anything, update the last archive date
        if didArchive {
            autoArchiveLog("Archiving complete, updating last archive date to \(now)")
            DefaultsKeys.lastAutoArchiveDate.setDate(now)
        }
    }
}