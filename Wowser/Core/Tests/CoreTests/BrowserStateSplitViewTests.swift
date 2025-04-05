import XCTest
@testable import Core

final class BrowserStateSplitViewTests: XCTestCase {
    
    func testMoveToSplitView() {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Create a window to work with
        let window = state.newWindow()
        
        // Create source tab with two panes
        let sourceUrl1 = URL(string: "https://example1.com")!
        let sourceUrl2 = URL(string: "https://example2.com")!
        let sourceTab = Tab.newTabWithURL(sourceUrl1)
        state.insertTab(sourceTab, location: .ordinaryTabs(0), inWindow: window.id)
        
        // Add a second pane to the source tab
        state.modifyTab(id: sourceTab.id) { tab in
            let paneID = Core.ID<WebContent>.assign()
            tab.panes.append(Pane(id: paneID, info: WebContent.Info(url: sourceUrl2)))
        }
        
        // Create destination tab
        let destUrl = URL(string: "https://destination.com")!
        let destTab = Tab.newTabWithURL(destUrl)
        state.insertTab(destTab, location: .ordinaryTabs(1), inWindow: window.id)
        
        // Verify initial state
        XCTAssertEqual(state.tabsInVisibleOrder(inWindow: window.id).count, 2, "Should have two tabs")
        
        // Get the source pane ID to move
        let sourcePaneId = sourceTab.panes[0]!.id
        
        // Move the first pane from source tab to destination tab
        let success = state.moveToSplitView(
            sourceTabId: sourceTab.id,
            sourcePaneId: sourcePaneId,
            destinationTabId: destTab.id,
            activatePane: true
        )
        
        // Verify the operation was successful
        XCTAssertTrue(success, "Move to split view operation should succeed")
        
        // Get updated tabs from state
        let updatedSourceTab = state.findTab(id: sourceTab.id)
        let updatedDestTab = state.findTab(id: destTab.id)
        
        // Verify source tab still exists with one pane
        XCTAssertNotNil(updatedSourceTab, "Source tab should still exist")
        XCTAssertEqual(updatedSourceTab?.panes.count, 1, "Source tab should have one pane left")
        XCTAssertEqual(updatedSourceTab?.panes[0]?.info.url, sourceUrl2, "Remaining pane should have the second URL")
        
        // Verify destination tab now has two panes
        XCTAssertEqual(updatedDestTab?.panes.count, 2, "Destination tab should now have two panes")
        XCTAssertEqual(updatedDestTab?.panes[1]?.info.url, sourceUrl1, "Second pane should have the first source URL")
        
        // Verify the moved pane is focused in destination tab
        XCTAssertEqual(updatedDestTab?.focusedPaneIdx, 1, "Moved pane should be focused")
    }
    
    func testMoveAllPanesToSplitView() {
        // Start with a default state
        var state = BrowserState.defaultState
        
        // Create a window to work with
        let window = state.newWindow()
        
        // Create source tab with three panes
        let sourceUrl1 = URL(string: "https://example1.com")!
        let sourceUrl2 = URL(string: "https://example2.com")!
        let sourceUrl3 = URL(string: "https://example3.com")!
        
        let sourceTab = Tab.newTabWithURL(sourceUrl1)
        state.insertTab(sourceTab, location: .ordinaryTabs(0), inWindow: window.id)
        
        // Add more panes to the source tab
        state.modifyTab(id: sourceTab.id) { tab in
            let paneID2 = Core.ID<WebContent>.assign()
            tab.panes.append(Pane(id: paneID2, info: WebContent.Info(url: sourceUrl2)))
            
            let paneID3 = Core.ID<WebContent>.assign()
            tab.panes.append(Pane(id: paneID3, info: WebContent.Info(url: sourceUrl3)))
        }
        
        // Create destination tab
        let destUrl = URL(string: "https://destination.com")!
        let destTab = Tab.newTabWithURL(destUrl)
        state.insertTab(destTab, location: .ordinaryTabs(1), inWindow: window.id)
        
        // Verify initial state
        XCTAssertEqual(state.tabsInVisibleOrder(inWindow: window.id).count, 2, "Should have two tabs")
        
        // Move all panes from source to destination
        let success = state.moveAllPanesToSplitView(
            sourceTabId: sourceTab.id,
            destinationTabId: destTab.id,
            activateLast: true
        )
        
        // Verify the operation was successful
        XCTAssertTrue(success, "Move all panes operation should succeed")
        
        // Verify source tab was removed
        XCTAssertNil(state.findTab(id: sourceTab.id), "Source tab should be removed")
        
        // Verify we now have only one tab
        XCTAssertEqual(state.tabsInVisibleOrder(inWindow: window.id).count, 1, "Should have one tab remaining")
        
        // Get updated destination tab
        let updatedDestTab = state.findTab(id: destTab.id)
        
        // Verify destination tab now has all four panes
        XCTAssertEqual(updatedDestTab?.panes.count, 4, "Destination tab should now have four panes")
        
        // Verify last pane is focused
        XCTAssertEqual(updatedDestTab?.focusedPaneIdx, 3, "Last moved pane should be focused")
    }
}

// Helper extension for tests
extension BrowserState {
    func findTab(id: ID<Tab>) -> Tab? {
        for window in windows.values {
            if window.tabs.contains(id) {
                return tabs[id]
            }
        }
        
        for project in projects.values {
            if project.tabs.contains(id) {
                return tabs[id]
            }
        }
        
        for profile in profiles.values {
            if profile.manualFavorites.contains(id) || profile.autoFavorites.contains(id) {
                return tabs[id]
            }
        }
        
        return nil
    }
}