import XCTest
@testable import Core

final class BrowserStateDragDropTests: XCTestCase {
    
    func testCanMoveSameProfile() {
        // Setup a browser state with two windows in the same profile
        var state = BrowserState.defaultState
        let profileId = ID<Profile>(raw: "p0")
        
        // Create windows
        let window1Id = ID<WindowState>(raw: "win1")
        let window2Id = ID<WindowState>(raw: "win2")
        state.windows[window1Id] = WindowState(id: window1Id, profile: profileId)
        state.windows[window2Id] = WindowState(id: window2Id, profile: profileId)
        
        // Create and insert a tab using proper API
        let tab = Tab.newEmptyTab()
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: window1Id)
        
        // Test that tab can be moved to another window in same profile
        let dest = TabDropDestination.ordinaryTabs(window: window2Id, before: nil)
        XCTAssertTrue(state.canMove(tab: tab.id, to: dest), "Should be able to move tab between windows in same profile")
    }
    
    func testMoveTabBetweenWindows() {
        // Setup a browser state
        var state = BrowserState.defaultState
        let profileId = ID<Profile>(raw: "p0")
        
        // Create windows
        let window1Id = ID<WindowState>(raw: "win1")
        let window2Id = ID<WindowState>(raw: "win2")
        state.windows[window1Id] = WindowState(id: window1Id, profile: profileId)
        state.windows[window2Id] = WindowState(id: window2Id, profile: profileId)
        
        // Create and insert a tab using proper API
        let tab = Tab.newEmptyTab()
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: window1Id)
        
        // Set tab as active in first window
        state.activate(tabId: tab.id, in: window1Id)
        
        // Move tab from window1 to window2 and make it active
        let dest = TabDropDestination.ordinaryTabs(window: window2Id, before: nil)
        state.move(tab: tab.id, to: dest, makeActiveInWindow: window2Id)
        
        // Verify tab was moved correctly
        XCTAssertFalse(state.windows[window1Id]?.tabs.contains(tab.id) ?? true, "Tab should be removed from source window")
        XCTAssertTrue(state.windows[window2Id]?.tabs.contains(tab.id) ?? false, "Tab should be added to destination window")
        XCTAssertNil(state.windows[window1Id]?.currentTab, "Tab should no longer be active in source window")
        XCTAssertEqual(state.windows[window2Id]?.currentTab, tab.id, "Tab should be active in destination window")
    }
    
    func testMoveTabToProject() {
        // Setup a browser state
        var state = BrowserState.defaultState
        let profileId = ID<Profile>(raw: "p0")
        
        // Create window
        let windowId = ID<WindowState>(raw: "win1")
        state.windows[windowId] = WindowState(id: windowId, profile: profileId)
        
        // Create project
        let projectId = ID<Project>(raw: "proj1")
        state.projects[projectId] = Project(id: projectId, profile: profileId)
        
        // Create and insert tab using proper API
        let tab = Tab.newEmptyTab()
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: windowId)
        
        // Move tab to project
        let dest = TabDropDestination.project(project: projectId, before: nil)
        state.move(tab: tab.id, to: dest, makeActiveInWindow: nil)
        
        // Verify tab was moved correctly
        XCTAssertFalse(state.windows[windowId]?.tabs.contains(tab.id) ?? true, "Tab should be removed from window")
        XCTAssertTrue(state.projects[projectId]?.tabs.contains(tab.id) ?? false, "Tab should be added to project")
    }
}
