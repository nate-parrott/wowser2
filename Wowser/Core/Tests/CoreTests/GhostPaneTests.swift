import XCTest
@testable import Core

final class GhostPaneTests: XCTestCase {

    func testUnghostTabClearsAllPanes() {
        let paneA = ID<WebContent>(raw: "pa")
        let paneB = ID<WebContent>(raw: "pb")
        var p1 = Pane(id: paneA, info: WebContent.Info(url: URL(string: "https://a.com")))
        p1.isGhost = true
        var p2 = Pane(id: paneB, info: WebContent.Info(url: URL(string: "https://b.com")))
        p2.isGhost = true

        var state = BrowserState.defaultState
        let win = state.newWindow()
        let tab = Tab(id: ID<Tab>(raw: "t1"), panes: [p1, p2])
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: win.id)

        // Sanity: both panes ghost beforehand.
        let pre = state.tabs[tab.id]?.panes.asArray ?? []
        XCTAssertEqual(pre.count, 2)
        XCTAssertTrue(pre.allSatisfy { $0.isGhost })

        state.unghostTab(id: tab.id)
        let post = state.tabs[tab.id]?.panes.asArray ?? []
        XCTAssertEqual(post.count, 2)
        XCTAssertTrue(post.allSatisfy { !$0.isGhost })
    }

    func testGhostPaneAppearanceShowsAgentSubtitle() {
        var pane = Pane(id: ID<WebContent>(raw: "p"), info: WebContent.Info(url: URL(string: "https://example.com")))
        pane.isGhost = true
        let appearance = pane.tabAppearance()
        XCTAssertEqual(appearance.subtitle, "Agent tab")
        XCTAssertTrue(appearance.isGhost)
    }

    func testNonGhostPaneHasNoSubtitle() {
        let pane = Pane(id: ID<WebContent>(raw: "p"), info: WebContent.Info(url: URL(string: "https://example.com")))
        let appearance = pane.tabAppearance()
        XCTAssertNil(appearance.subtitle)
        XCTAssertFalse(appearance.isGhost)
    }
}
