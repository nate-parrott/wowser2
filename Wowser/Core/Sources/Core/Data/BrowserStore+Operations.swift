import Foundation

extension BrowserStore {
    /// Closes all non-pinned tabs in the window and archives them
    /// - Parameter windowID: The ID of the window to clear tabs from
    public func clearAllTabs(in windowID: ID<WindowState>) {
        guard let window = model.windows[windowID] else { return }
        
        // Determine which tabs to close based on whether we're in a project or main window
        let tabsToClose = window.focusedOnProject != nil ? 
            (model.projects[window.focusedOnProject!]?.tabs ?? []) : 
            window.tabs
            
        // Filter out any pinned tabs and collect information for archive
        let tabsToRemove = tabsToClose.filter { !model.isPinned(tabId: $0) }
        
        // Archive tabs then close them
        for tabID in tabsToRemove {
            if let tab = model.tabs[tabID], 
               let pane = tab.panes.first,
               let url = pane.info.url {
                
                // Create archive item
                let archiveItem = ArchiveItem(
                    added: Date(),
                    url: url,
                    historyKey: url.historyKey,
                    title: pane.info.title,
                    kind: .autoArchivedTab
                )
                
                // Add to archive
                Queue.archiveQueue.run {
                    ArchiveStore.shared.add(item: archiveItem)
                }
                
                // Close the tab
                if let paneID = tab.panes.first?.id {
                    close(webContentId: paneID, removeIfPinned: false)
                }
            }
        }
    }
}