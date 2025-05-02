import AppKit
import SwiftUI

#if os(macOS)
public class ArchiveMenuManager: NSObject, NSMenuDelegate {
    let oldTabsMenu: NSMenu
    let oldTabsMenuItem: NSMenuItem
    let bookmarksMenuItem: NSMenuItem
    let openURL: (URL) -> Void
    
    private var dynamicMenuItems: [NSMenuItem] = []
    private var bookmarksMenu: NSMenu! { bookmarksMenuItem.submenu }
    
    static private(set) var shared: ArchiveMenuManager?
    
    public init(bookmarksMenuItem: NSMenuItem, openURL: @escaping (URL) -> Void) {
        self.oldTabsMenu = NSMenu(title: "Old Tabs")
        self.oldTabsMenuItem = NSMenuItem(title: "Old Tabs", action: nil, keyEquivalent: "")
        self.oldTabsMenu.items.append(.separator()) // need to have at least one item in the submenu for it to open
        oldTabsMenuItem.submenu = oldTabsMenu
        
        self.bookmarksMenuItem = bookmarksMenuItem
        self.openURL = openURL
        super.init()
        
        if Self.shared == nil {
            Self.shared = self
        }
        
        // Set up menu delegates
        oldTabsMenu.delegate = self
        bookmarksMenuItem.submenu?.delegate = self
        
        // Initialize menu visibility based on user settings
        oldTabsMenuVisible = UserDefaults.standard.bool(forKey: DefaultsKeys.autoArchiveTabs.rawValue)
        
        // Observe changes to auto archive setting
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenuVisibilityFromSettings()
        }
        
        // Set initial visibility
        updateOldTabsMenuVisibility()
    }
    
    var oldTabsMenuVisible = false {
        didSet {
            if oldTabsMenuVisible != oldValue {
                updateOldTabsMenuVisibility()
            }
        }
    }
    
    private func updateMenuVisibilityFromSettings() {
        oldTabsMenuVisible = UserDefaults.standard.bool(forKey: DefaultsKeys.autoArchiveTabs.rawValue)
    }
    
    private func updateOldTabsMenuVisibility() {
        if let mainMenu = NSApplication.shared.mainMenu {
            if oldTabsMenuVisible {
                // Only add if not already in menu
                if oldTabsMenuItem.menu == nil {
                    mainMenu.insertItem(oldTabsMenuItem, at: max(1, mainMenu.items.count - 3))
                }
            } else {
                // Remove if present
                if oldTabsMenuItem.menu != nil {
                    mainMenu.removeItem(oldTabsMenuItem)
                }
            }
        }
    }
    
    public func menuWillOpen(_ menu: NSMenu) {
        // Clear previously added dynamic items
        clearDynamicItems(from: menu)
        
        Task { @MainActor in
            if menu === oldTabsMenu {
                await populateOldTabsMenu()
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
    private func populateOldTabsMenu() async {
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
        if self.oldTabsMenu.items.count > 0 {
            let separator = NSMenuItem.separator()
            self.oldTabsMenu.addItem(separator)
            self.dynamicMenuItems.append(separator)
        }
        
        if recentItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No Old Tabs", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            self.oldTabsMenu.addItem(emptyItem)
            self.dynamicMenuItems.append(emptyItem)
        } else {
            // Group items by day
            let calendar = Calendar.current
            var itemsByDay: [Date: [ArchiveItem]] = [:]
            
            for item in recentItems {
                // Get the start of day for the item's date
                let startOfDay = calendar.startOfDay(for: item.added)
                if itemsByDay[startOfDay] == nil {
                    itemsByDay[startOfDay] = []
                }
                itemsByDay[startOfDay]?.append(item)
            }
            
            // Sort days (newest first)
            let sortedDays = itemsByDay.keys.sorted(by: >)
            
            // Add items by day with section headers
            var isFirstDay = true
            for day in sortedDays {
                // Don't add separator before the first day
                if !isFirstDay {
                    // Add a separator between days
                    let separator = NSMenuItem.separator()
                    self.oldTabsMenu.addItem(separator)
                    self.dynamicMenuItems.append(separator)
                }
                isFirstDay = false
                
                // Add day header
                let formatter = DateFormatter()
                
                // Check if the day is today, yesterday, or another day
                if calendar.isDateInToday(day) {
                    formatter.dateFormat = "'Today'"
                } else if calendar.isDateInYesterday(day) {
                    formatter.dateFormat = "'Yesterday'"
                } else {
                    formatter.dateFormat = "EEEE, MMM d" // e.g. "Monday, May 1"
                }
                
                let dateString = formatter.string(from: day)
                let titleItem = NSMenuItem(title: dateString, action: nil, keyEquivalent: "")
                titleItem.isEnabled = false
                self.oldTabsMenu.addItem(titleItem)
                self.dynamicMenuItems.append(titleItem)
                
                // Add items for this day
                if let items = itemsByDay[day] {
                    for item in items {
                        let menuItem = ArchiveMenuItem(archiveItem: item) { [weak self] in
                            self?.openURL(item.url)
                        }
                        self.oldTabsMenu.addItem(menuItem)
                        self.dynamicMenuItems.append(menuItem)
                    }
                }
            }
        }
    }
}

#endif