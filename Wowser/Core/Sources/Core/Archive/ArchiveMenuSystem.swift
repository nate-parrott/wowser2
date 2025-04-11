import AppKit
import SwiftUI

public class ArchiveMenuManager: NSObject, NSMenuDelegate {
    let historyMenu: NSMenu
    let bookmarksMenuItem: NSMenuItem
    let openURL: (URL) -> Void
    
    private var dynamicMenuItems: [NSMenuItem] = []
    private var bookmarksMenu: NSMenu! { bookmarksMenuItem.submenu }
    
    public init(historyMenu: NSMenu, bookmarksMenuItem: NSMenuItem, openURL: @escaping (URL) -> Void) {
        self.historyMenu = historyMenu
        self.bookmarksMenuItem = bookmarksMenuItem
        self.openURL = openURL
        super.init()
        
        // Set up menu delegates
        historyMenu.delegate = self
        bookmarksMenuItem.submenu?.delegate = self
    }
    
    public func menuWillOpen(_ menu: NSMenu) {
        // Clear previously added dynamic items
        clearDynamicItems(from: menu)
        
        Task { @MainActor in
            if menu === historyMenu {
                await populateHistoryMenu()
            } else if menu === bookmarksMenu {
                await populateBookmarksMenu()
            }
        }
    }
    
    private func clearDynamicItems(from menu: NSMenu) {
        // Filter out the items from this specific menu
        let itemsToRemove = dynamicMenuItems.filter { $0.menu === menu }
        
        // Remove them from the menu
        for item in itemsToRemove {
            menu.removeItem(item)
        }
        
        // Remove them from our tracking array
        dynamicMenuItems.removeAll { $0.menu === menu }
    }
    
    @MainActor
    private func populateBookmarksMenu() async {
        let state = await ArchiveStore.shared.readAsync()
        // Get all bookmark items
        let bookmarks = state.itemsByHistoryKey.values
            .filter { $0.kind == .bookmark }
            .sorted { $0.added > $1.added }
        if bookmarks.isEmpty {
            let emptyItem = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            self.bookmarksMenu.addItem(emptyItem)
            self.dynamicMenuItems.append(emptyItem)
        } else {
            for bookmark in bookmarks {
                let menuItem = ArchiveMenuItem(archiveItem: bookmark) { [weak self] in
                    self?.openURL(bookmark.url)
                }
                self.bookmarksMenu.addItem(menuItem)
                self.dynamicMenuItems.append(menuItem)
            }
        }
    }
    
    @MainActor
    private func populateHistoryMenu() async {
        let state = await ArchiveStore.shared.readAsync()
        let cutoffDate = Date().addingTimeInterval(-48 * 60 * 60) // 48 hours ago
        let recentItems = state.itemsByHistoryKey.values
            .filter { 
                // Only show archived tabs (auto or manual), not bookmarks
                ($0.kind == .autoArchivedTab || $0.kind == .manuallyArchivedTab) &&
                $0.added >= cutoffDate 
            }
            .sorted { $0.added > $1.added }
            .prefix(40)
        
        // Add separator if menu already has items
        if self.historyMenu.items.count > 0 {
            let separator = NSMenuItem.separator()
            self.historyMenu.addItem(separator)
            self.dynamicMenuItems.append(separator)
        }
        
        // Add section title
        let titleItem = NSMenuItem(title: "Recently Archived", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        self.historyMenu.addItem(titleItem)
        self.dynamicMenuItems.append(titleItem)
        
        if recentItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Archived Items", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            self.historyMenu.addItem(emptyItem)
            self.dynamicMenuItems.append(emptyItem)
        } else {
            for item in recentItems {
                let menuItem = ArchiveMenuItem(archiveItem: item) { [weak self] in
                    self?.openURL(item.url)
                }
                self.historyMenu.addItem(menuItem)
                self.dynamicMenuItems.append(menuItem)
            }
        }
    }
}
