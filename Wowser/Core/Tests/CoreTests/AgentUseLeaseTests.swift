import XCTest
@testable import Core

/// `Pane.agentActiveUntil` lease semantics behind `browser.tabs.use` and the
/// agent stage's expiry sweep. Pure `BrowserState` — no store, no main actor.
final class AgentUseLeaseTests: XCTestCase {

    private func makeState() -> (BrowserState, ID<WebContent>) {
        var state = BrowserState.defaultState
        let win = WindowState(id: .assign(), profile: .defaultProfile)
        state.windows[win.id] = win
        let pane = Pane(id: .assign(), info: WebContent.Info(url: URL(string: "https://a.example")!))
        state.insertTab(Tab(id: .assign(), panes: [pane]), location: .ordinaryTabs(0), inWindow: win.id)
        return (state, pane.id)
    }

    private func until(_ state: BrowserState, _ id: ID<WebContent>) -> Date? {
        state.tabs[state.paneToTabMapping[id]!]!.panes[id]!.agentActiveUntil
    }

    func testSetAndRelease() {
        var (state, id) = makeState()
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(state.setAgentUse(paneID: id, until: t))
        XCTAssertEqual(until(state, id), t)
        XCTAssertTrue(state.setAgentUse(paneID: id, until: nil))
        XCTAssertNil(until(state, id))
        XCTAssertFalse(state.setAgentUse(paneID: .assign(), until: t), "unknown pane")
    }

    func testTouchExtendsOnlyWhenLeaseIsGettingShort() {
        var (state, id) = makeState()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(state.touchAgentUse(paneID: id, now: now, lease: 3600, slack: 600))
        XCTAssertEqual(until(state, id), now.addingTimeInterval(3600))

        // Five minutes later the lease still has > 50 min left → no rewrite.
        XCTAssertFalse(state.touchAgentUse(paneID: id, now: now.addingTimeInterval(300), lease: 3600, slack: 600))
        XCTAssertEqual(until(state, id), now.addingTimeInterval(3600))

        // Fifteen minutes in, under the slack threshold → renewed from now.
        let later = now.addingTimeInterval(900)
        XCTAssertTrue(state.touchAgentUse(paneID: id, now: later, lease: 3600, slack: 600))
        XCTAssertEqual(until(state, id), later.addingTimeInterval(3600))
    }

    func testSweepReleasesOnlyExpired() {
        var (state, id) = makeState()
        let now = Date(timeIntervalSince1970: 50_000)
        state.setAgentUse(paneID: id, until: now.addingTimeInterval(60))
        XCTAssertEqual(state.sweepExpiredAgentUse(now: now), [])
        XCTAssertNotNil(until(state, id))
        XCTAssertEqual(state.sweepExpiredAgentUse(now: now.addingTimeInterval(61)), [id])
        XCTAssertNil(until(state, id))
    }

    func testSubtitleReflectsLease() {
        var (state, id) = makeState()
        let tabID = state.paneToTabMapping[id]!
        XCTAssertNil(state.tabs[tabID]!.appearance().subtitle)
        state.setAgentUse(paneID: id, until: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(state.tabs[tabID]!.appearance().subtitle, "Agent is using this tab")
    }
}
