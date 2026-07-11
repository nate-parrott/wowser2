import XCTest
@testable import Core

#if os(macOS)
/// State-layer invariants that the BrowserJS `splits` / `spaces` surface relies
/// on. These run against `BrowserState` directly (a value type), so they need
/// neither the main actor nor a live `BrowserStore`.
final class SplitsAndSpacesStateTests: XCTestCase {

    private func pane(_ url: String) -> Pane {
        Pane(id: .assign(), info: WebContent.Info(url: URL(string: url)!))
    }

    // MARK: - Tab.focusedPane / isSplit

    func testFocusedPaneTracksFocusedPaneIdx() {
        let a = pane("https://a.example"), b = pane("https://b.example")
        var tab = Tab(id: .assign(), panes: [a, b])

        XCTAssertEqual(tab.focusedPane?.id, a.id, "focusedPaneIdx defaults to 0")
        tab.focusedPaneIdx = 1
        XCTAssertEqual(tab.focusedPane?.id, b.id)
    }

    func testFocusedPaneIsNilForEmptyTabAndNeverOutOfBounds() {
        var tab = Tab(id: .assign(), panes: [])
        XCTAssertNil(tab.focusedPane)

        // `panes.didSet` clamps focusedPaneIdx, so focusedPane can't index past the end.
        tab.panes = .init(items: [pane("https://a.example"), pane("https://b.example")])
        tab.focusedPaneIdx = 1
        tab.panes = .init(items: [pane("https://c.example")])
        XCTAssertEqual(tab.focusedPaneIdx, 0)
        XCTAssertNotNil(tab.focusedPane)
    }

    func testIsSplit() {
        XCTAssertFalse(Tab(id: .assign(), panes: [pane("https://a.example")]).isSplit)
        XCTAssertTrue(Tab(id: .assign(), panes: [pane("https://a.example"), pane("https://b.example")]).isSplit)
    }

    // MARK: - splits.separate preserves pane ids

    /// `splits.separate` hands pane ids back to JS as still-valid TabIds, so the
    /// underlying `separateSplitTabs` must not re-mint them.
    func testSeparateSplitTabsPreservesPaneIdentity() {
        var state = BrowserState.defaultState
        let win = WindowState(id: .assign(), profile: .defaultProfile)
        state.windows[win.id] = win

        let a = pane("https://a.example"), b = pane("https://b.example"), c = pane("https://c.example")
        let tab = Tab(id: .assign(), panes: [a, b, c])
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: win.id)
        XCTAssertEqual(state.tabs[tab.id]?.panes.count, 3)

        let resultTabIDs = state.separateSplitTabs(tabId: tab.id)
        XCTAssertEqual(resultTabIDs.count, 3, "one tab per pane")

        // Every original pane id still resolves, now each in its own tab.
        for paneID in [a.id, b.id, c.id] {
            guard let owningTab = state.paneToTabMapping[paneID] else {
                return XCTFail("pane \(paneID.raw) lost its tab mapping")
            }
            XCTAssertEqual(state.tabs[owningTab]?.panes.count, 1)
        }
        XCTAssertEqual(Set(resultTabIDs), Set([a.id, b.id, c.id].compactMap { state.paneToTabMapping[$0] }))
    }

    func testSeparateSplitTabsIsNoOpForSinglePaneTab() {
        var state = BrowserState.defaultState
        let win = WindowState(id: .assign(), profile: .defaultProfile)
        state.windows[win.id] = win
        let tab = Tab(id: .assign(), panes: [pane("https://a.example")])
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: win.id)

        XCTAssertEqual(state.separateSplitTabs(tabId: tab.id), [], "nothing to separate")
        XCTAssertEqual(state.tabs[tab.id]?.panes.count, 1)
    }

    // MARK: - A space's tab list is per-window

    /// The whole reason `spaces.list` reports `tabIds` relative to a window:
    /// `WindowState.tabs` reads through `perProfileData[profile]`, so the same
    /// space holds a different tab list in each window.
    func testSpaceTabListIsPerWindow() {
        var state = BrowserState.defaultState
        let spaceA = ID<Profile>.defaultProfile
        let spaceB = state.createNewProfile()

        var win = WindowState(id: .assign(), profile: spaceA)
        state.windows[win.id] = win

        let tabInA = Tab(id: .assign(), panes: [pane("https://a.example")])
        state.insertTab(tabInA, location: .ordinaryTabs(0), inWindow: win.id)
        XCTAssertEqual(state.windows[win.id]?.tabs, [tabInA.id])

        // Switch the window to space B: its tab list is independent, not shared.
        state.windows[win.id]?.profile = spaceB
        XCTAssertEqual(state.windows[win.id]?.tabs, [], "space B starts with no tabs in this window")

        let tabInB = Tab(id: .assign(), panes: [pane("https://b.example")])
        state.insertTab(tabInB, location: .ordinaryTabs(0), inWindow: win.id)
        XCTAssertEqual(state.windows[win.id]?.tabs, [tabInB.id])

        // Space A's tabs are intact, reachable via perProfileData.
        XCTAssertEqual(state.windows[win.id]?.perProfileData[spaceA]?.tabs, [tabInA.id])

        // Switching back restores them.
        state.windows[win.id]?.profile = spaceA
        XCTAssertEqual(state.windows[win.id]?.tabs, [tabInA.id])
        win = state.windows[win.id]!
        XCTAssertEqual(win.perProfileData[spaceB]?.tabs, [tabInB.id])
    }

    func testHiddenSpacesAreExcludedFromVisibleProfiles() {
        var state = BrowserState.defaultState
        let extra = state.createNewProfile()
        XCTAssertEqual(state.visibleProfiles.count, 2)

        state.hideProfile(extra)
        XCTAssertEqual(state.visibleProfiles.map(\.id), [.defaultProfile])
        XCTAssertEqual(state.hiddenProfiles.map(\.id), [extra])

        // Never hide down to zero — this is what `spaces.activate` leans on when
        // it refuses to switch a window to a hidden space.
        XCTAssertFalse(state.canHideProfile(.defaultProfile))
    }
}
#endif
