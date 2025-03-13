import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func testIsPinnedTab() throws {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Create a window to work with
        let window = state.newWindow()
        
        // Create a tab (this will automatically add it to the window)
        let url = URL(string: "https://example.com")!
        let tab = state.openTab(url: url, activate: true)
        
        // Initially, the tab should not be pinned
        XCTAssertFalse(state.isPinned(tabId: tab.id), "New tab should not be pinned initially")
        
        // Add the tab to manual favorites in the window's profile
        let profileId = window.profile
        state.profiles[profileId]?.manualFavorites.append(tab.id)
        state.windows[window.id]?.tabs.removeAll(where: { $0 == tab.id })
        
        // Now the tab should be recognized as pinned
        XCTAssertTrue(state.isPinned(tabId: tab.id), "Tab should be pinned after adding to favorites")
        
        // Remove from manual favorites
        state.profiles[profileId]?.manualFavorites.removeAll()
        XCTAssertFalse(state.isPinned(tabId: tab.id), "Tab should not be pinned after removing from favorites")
        
        // Add to auto favorites
        state.profiles[profileId]?.autoFavorites.append(tab.id)
        XCTAssertTrue(state.isPinned(tabId: tab.id), "Tab should be pinned when in auto favorites")
    }
    
    func testBrowserStateInitialization() throws {
        // Test the default BrowserState initialization
        let state = BrowserState.defaultState
        
        // Verify default state has no windows and tabs
        XCTAssertTrue(state.windows.isEmpty, "Default state should have no windows")
        XCTAssertTrue(state.tabs.isEmpty, "Default state should have no tabs")
        
        // Verify default state has one profile
        XCTAssertEqual(state.profiles.count, 1, "Default state should have one profile")
        XCTAssertEqual(state.profiles.first?.key.raw, "p0", "Default profile ID should be 'p0'")
        
        // Verify default state has no projects
        XCTAssertTrue(state.projects.isEmpty, "Default state should have no projects")
    }
    
    func testOpenAndCloseTab() throws {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Open a new tab with a URL
        let url = URL(string: "https://example.com")!
        let tab = state.openTab(url: url, activate: true)
        
        // Verify tab was added
        XCTAssertEqual(state.tabs.count, 1, "State should have one tab after adding")
        XCTAssertEqual(state.tabs[tab.id]?.panes.count, 1, "Tab should have one pane")
        XCTAssertEqual(state.tabs[tab.id]?.panes[0]?.info.url, url, "Tab's pane should have the correct URL")
        
        // Verify window was created and tab is active
        XCTAssertEqual(state.windows.count, 1, "One window should be created")
        let window = state.windows.first!.value
        XCTAssertEqual(window.currentTab, tab.id, "Tab should be the current tab in window")
        XCTAssertEqual(window.tabs.count, 1, "Window should have one tab")
        
        // Close the tab's pane
        let paneID = state.tabs[tab.id]!.panes[0]!.id
        state._close(webContentId: paneID, removeIfPinned: true)
        
        // Verify tab was removed
        XCTAssertEqual(state.tabs.count, 0, "State should have no tabs after closing")
        XCTAssertTrue(state.paneToTabMapping.isEmpty, "Pane-to-tab mapping should be empty")
        XCTAssertEqual(state.windows.first!.value.tabs.count, 0, "Window should have no tabs")
        XCTAssertNil(state.windows.first!.value.currentTab, "Window should have no current tab")
    }
    
    func testWindowManagement() throws {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Create a new window
        let window = state.newWindow()
        
        // Verify window was created with the default profile
        XCTAssertEqual(state.windows.count, 1, "State should have one window")
        XCTAssertEqual(window.profile, state.profiles.first!.key, "Window should use the default profile")
        
        // Get the active window
        let activeWindow = state.activeWindow
        XCTAssertNotNil(activeWindow, "There should be an active window")
        XCTAssertEqual(activeWindow?.id, window.id, "The created window should be active")
        
        // Get or create active window should return the existing window
        let existingWindow = state.getOrCreateActiveWindow()
        XCTAssertEqual(existingWindow.id, window.id, "Should return the existing window")
        XCTAssertEqual(state.windows.count, 1, "Should not create a new window")
    }
    
    func testMultipleTabManagement() throws {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Open multiple tabs
        let url1 = URL(string: "https://example1.com")!
        let url2 = URL(string: "https://example2.com")!
        let url3 = URL(string: "https://example3.com")!
        
        let tab1 = state.openTab(url: url1, activate: true)
        let tab2 = state.openTab(url: url2, activate: true)
        let tab3 = state.openTab(url: url3, activate: true)
        
        // Verify all tabs were added
        XCTAssertEqual(state.tabs.count, 3, "State should have three tabs")
        
        XCTAssertEqual(state.windows[state.windows.keys.first!]!.tabs, [tab1.id, tab2.id, tab3.id])
        
        // Verify window structure
        XCTAssertEqual(state.windows.count, 1, "Should have one window")
        XCTAssertEqual(state.windows.values.first!.tabs.count, 3, "Window should have three tabs")
        
        // Verify active tab
        XCTAssertEqual(state.windows.values.first!.currentTab, tab3.id, "Tab3 should be active")
        
        // Test tab selection after closing
        let nextTabToSelect = state.tabToSelectAfterClosing(tabId: tab3.id)
        XCTAssertEqual(nextTabToSelect, tab2.id, "Should select tab2 after closing tab3")
        
        // Close middle tab
        let paneID2 = state.tabs[tab2.id]!.panes[0]!.id
        state._close(webContentId: paneID2, removeIfPinned: true)
        
        // Verify tab was removed
        XCTAssertEqual(state.tabs.count, 2, "Should have two tabs after closing one")
        XCTAssertEqual(state.windows.values.first!.tabs.count, 2, "Window should have two tabs")
        XCTAssertFalse(state.tabs.keys.contains(tab2.id), "Tab2 should be removed")
        XCTAssertTrue(state.tabs.keys.contains(tab1.id), "Tab1 should still exist")
        XCTAssertTrue(state.tabs.keys.contains(tab3.id), "Tab3 should still exist")
    }
}
