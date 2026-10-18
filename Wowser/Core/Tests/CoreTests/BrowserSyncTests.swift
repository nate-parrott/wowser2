import XCTest
import Combine
@testable import Core

/// A BrowserState value standing in for a device's BrowserStore. Applies
/// synchronously; `live` = panes that have a webview on this device.
final class BrowserStateSyncSource: SyncSource {
    let id = "browser"
    var state: BrowserState
    var live = Set<ID<WebContent>>()
    var effects = [BrowserSyncEffect]()

    init(state: BrowserState) { self.state = state }

    var collections: [SyncCollectionSpec] { BrowserSyncSchema.collections }
    var localChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func project() -> SyncProjection? { state.syncProjection() }
    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        effects += state.applySync(update, livePanes: live)
        completion()
    }
}

final class BrowserSyncTests: XCTestCase {
    var t = Date(timeIntervalSince1970: 2_000_000)

    struct Device {
        let source: BrowserStateSyncSource
        let engine: SyncEngine
        var state: BrowserState {
            get { source.state }
            nonmutating set { source.state = newValue }
        }
        var window: ID<WindowState> { source.state.syncPrimaryWindow!.id }
        func tabs(_ space: ID<Profile> = .defaultProfile) -> [ID<Tab>] {
            source.state.windows[window]?.perProfileData[space]?.tabs ?? []
        }
        func urls(_ space: ID<Profile> = .defaultProfile) -> [String] {
            tabs(space).compactMap { source.state.tabs[$0]?.panes.first?.info.url?.absoluteString }
        }
        func pane(_ tab: ID<Tab>) -> Pane? { source.state.tabs[tab]?.panes.first }
    }

    func makeHub() -> InMemorySyncHub { InMemorySyncHub(now: { [unowned self] in self.t }) }

    func makeDevice(_ name: String, hub: InMemorySyncHub, configure: (inout BrowserState) -> Void = { _ in }) -> Device {
        var state = BrowserState.defaultState
        _ = state.newWindow()
        configure(&state)
        let source = BrowserStateSyncSource(state: state)
        let engine = SyncEngine(sources: [source], transport: hub.transport(device: name), storage: InMemorySyncEngineStorage(state: SyncEngineState(deviceID: name)), deviceName: name, throttle: 0, now: { [unowned self] in self.t })
        return Device(source: source, engine: engine)
    }

    func settle(_ devices: [Device], rounds: Int = 5) {
        for _ in 0..<rounds {
            for d in devices { d.engine.runUntilQuiet() }
            t = t.addingTimeInterval(1)
        }
    }

    @discardableResult
    func open(_ url: String, on d: Device, space: ID<Profile>? = nil) -> ID<Tab> {
        if let space { d.state.windows[d.window]?.profile = space }
        return d.state.openTab(url: URL(string: url)!, activate: false, windowID: d.window).id
    }

    func navigate(_ tab: ID<Tab>, to url: String, title: String? = nil, on d: Device) {
        let paneID = d.state.tabs[tab]!.panes.first!.id
        d.state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
            pane.info = WebContent.Info(url: URL(string: url)!, title: title)
        }
    }

    func assertSameSyncedState(_ a: Device, _ b: Device, file: StaticString = #filePath, line: UInt = #line) {
        let pa = a.state.syncProjection()!, pb = b.state.syncProjection()!
        XCTAssertEqual(pa.lists, pb.lists, "lists differ", file: file, line: line)
        for col in [BrowserSyncSchema.space, BrowserSyncSchema.tab, BrowserSyncSchema.pane] {
            XCTAssertEqual(pa.records[col], pb.records[col], "\(col) records differ", file: file, line: line)
        }
    }

    // MARK: - Tabs

    func testNewTabsAppearInOrderOnOtherDevice() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        settle([a, b])
        let t1 = open("https://one.example/", on: a)
        open("https://two.example/", on: a)
        navigate(t1, to: "https://one.example/", title: "One", on: a)
        settle([a, b])
        XCTAssertEqual(b.urls(), ["https://one.example/", "https://two.example/"])
        XCTAssertEqual(b.pane(t1)?.info.title, "One")
        assertSameSyncedState(a, b)
    }

    func testJoiningDeviceKeepsItsTabsAndAddsRemoteOnes() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub)
        open("https://a.example/", on: a)
        settle([a])
        let b = makeDevice("B", hub: hub)
        open("https://b.example/", on: b)
        settle([a, b])
        XCTAssertEqual(Set(a.urls()), ["https://a.example/", "https://b.example/"])
        assertSameSyncedState(a, b)
    }

    func testClosingTabPropagatesAndReselects() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let keep = open("https://keep.example/", on: a)
        let close = open("https://close.example/", on: a)
        settle([a, b])
        b.state.activate(tabId: close, in: b.window)
        let paneID = a.state.tabs[close]!.panes.first!.id
        a.state._close(webContentId: paneID, removeIfPinned: false)
        settle([a, b])
        XCTAssertNil(b.state.tabs[close])
        XCTAssertEqual(b.tabs(), [keep])
        XCTAssertEqual(b.state.windows[b.window]?.currentTab, keep, "B was looking at it; a neighbor is selected")
    }

    func testReorderTabs() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let ids = ["1", "2", "3", "4"].map { open("https://\($0).example/", on: a) }
        settle([a, b])
        b.state.windows[b.window]!.perProfileData[.defaultProfile]!.tabs = [ids[3], ids[0], ids[1], ids[2]]
        settle([a, b])
        XCTAssertEqual(a.tabs(), [ids[3], ids[0], ids[1], ids[2]])
    }

    func testTabMovesBetweenSpaces() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let work = a.state.createNewProfile()
        let tab = open("https://move.example/", on: a)
        settle([a, b])
        // Move it into Work on A.
        a.state.windows[a.window]!.perProfileData[.defaultProfile]!.tabs.removeAll { $0 == tab }
        a.state.windows[a.window]!.perProfileData[work, default: .init(tabs: [])].tabs.append(tab)
        settle([a, b])
        XCTAssertFalse(b.tabs().contains(tab))
        XCTAssertEqual(b.tabs(work), [tab])
    }

    // MARK: - Navigation fights

    func testNavigationOfBackgroundTabApplies() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let tab = open("https://start.example/", on: a)
        settle([a, b])
        navigate(tab, to: "https://next.example/", title: "Next", on: a)
        settle([a, b])
        XCTAssertEqual(b.pane(tab)?.info.url?.absoluteString, "https://next.example/")
        XCTAssertEqual(b.pane(tab)?.info.title, "Next")
        XCTAssertNil(b.pane(tab)?.syncPendingNav)
    }

    func testNavigationOfLiveTabWaitsForReopen() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let tab = open("https://start.example/", on: a)
        settle([a, b])
        b.source.live = [b.pane(tab)!.id]
        navigate(tab, to: "https://remote.example/", on: a)
        settle([a, b])
        XCTAssertEqual(b.pane(tab)?.info.url?.absoluteString, "https://start.example/", "the open page isn't yanked away")
        XCTAssertEqual(b.pane(tab)?.syncPendingNav?.url?.absoluteString, "https://remote.example/")
        XCTAssertEqual(a.pane(tab)?.info.url?.absoluteString, "https://remote.example/", "B doesn't fight back")

        let loads = b.state.adoptSyncPendingNavigations(tabID: tab)
        XCTAssertEqual(loads.map(\.url.absoluteString), ["https://remote.example/"])
        XCTAssertEqual(b.pane(tab)?.info.url?.absoluteString, "https://remote.example/")
        let sent = hub.batches(from: "B").count
        settle([a, b])
        XCTAssertEqual(hub.batches(from: "B").count, sent, "reopening doesn't write anything")
    }

    func testLocalNavigationBeatsParkedRemoteOne() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let tab = open("https://start.example/", on: a)
        settle([a, b])
        b.source.live = [b.pane(tab)!.id]
        navigate(tab, to: "https://remote.example/", on: a)
        settle([a, b])
        // The user on B clicks a link in the open page.
        navigate(tab, to: "https://local.example/", on: b)
        b.state.dropSyncPendingNav(paneID: b.pane(tab)!.id)
        settle([a, b])
        XCTAssertEqual(a.pane(tab)?.info.url?.absoluteString, "https://local.example/")
        XCTAssertNil(b.pane(tab)?.syncPendingNav)
    }

    func testSameURLOnLiveTabOnlyRefreshesTitle() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let tab = open("https://same.example/", on: a)
        settle([a, b])
        b.source.live = [b.pane(tab)!.id]
        navigate(tab, to: "https://same.example/", title: "New title", on: a)
        settle([a, b])
        XCTAssertNil(b.pane(tab)?.syncPendingNav)
        XCTAssertEqual(b.pane(tab)?.info.title, "New title")
    }

    func testTerminalSpinnerGlyphIsNotSynced() {
        XCTAssertEqual(Pane.syncTitle("◐ Fixing bugs"), "Fixing bugs")
        XCTAssertEqual(Pane.syncTitle("✳ Fixing bugs"), "Fixing bugs")
        XCTAssertEqual(Pane.syncTitle("Plain"), "Plain")
    }

    // MARK: - Spaces

    func testSpacesSyncMetadataAndOrder() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let work = a.state.createNewProfile()
        a.state.profiles[work]?.title = "Work"
        a.state.profiles[work]?.emoji = "💼"
        a.state.profiles[.defaultProfile]?.title = "Home"
        settle([a, b])
        XCTAssertEqual(b.state.profiles[work]?.title, "Work")
        XCTAssertEqual(b.state.profiles[work]?.emoji, "💼")
        XCTAssertEqual(b.state.profiles[.defaultProfile]?.title, "Home")
        XCTAssertEqual(b.state.visibleProfiles.map(\.id), [.defaultProfile, work])

        b.state.moveProfile(work, toPositionOf: .defaultProfile)
        b.state.hideProfile(.defaultProfile)
        settle([a, b])
        XCTAssertEqual(a.state.profiles.values.sorted { $0.creationOrder < $1.creationOrder }.map(\.id), [work, .defaultProfile])
        XCTAssertEqual(a.state.profiles[.defaultProfile]?.isHidden, true)
    }

    func testDefaultSpaceAdoptsExistingValuesOnJoinAndKeepsCookieJar() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub) { $0.profiles[.defaultProfile]?.title = "Home" }
        settle([a])
        let b = makeDevice("B", hub: hub) { $0.profiles[.defaultProfile]?.title = "Mine" }
        let bJar = b.state.profiles[.defaultProfile]!.dataStoreUUID
        settle([a, b])
        XCTAssertEqual(b.state.profiles[.defaultProfile]?.title, "Home")
        XCTAssertEqual(a.state.profiles[.defaultProfile]?.title, "Home")
        XCTAssertEqual(b.state.profiles[.defaultProfile]?.dataStoreUUID, bJar, "B isn't logged out of its own space")
        XCTAssertEqual(b.state.syncLoginGroup(forDataStore: bJar), a.state.syncLoginGroup(forDataStore: a.state.profiles[.defaultProfile]!.dataStoreUUID))
    }

    func testLoginGroupsRecreateSharedCookieJars() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        settle([a, b])
        let shared = a.state.createNewProfile(sharingLoginsWith: .defaultProfile)
        let isolated = a.state.createNewProfile()
        let isolated2 = a.state.createNewProfile(sharingLoginsWith: isolated)
        settle([a, b])
        let p = b.state.profiles
        XCTAssertEqual(p[shared]?.dataStoreUUID, p[.defaultProfile]?.dataStoreUUID)
        XCTAssertNotEqual(p[isolated]?.dataStoreUUID, p[.defaultProfile]?.dataStoreUUID)
        XCTAssertEqual(p[isolated2]?.dataStoreUUID, p[isolated]?.dataStoreUUID)
        XCTAssertEqual(b.state.allLoginGroups.count, 2)
    }

    func testDeletingSpaceRemovesItAndItsTabs() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let work = a.state.createNewProfile()
        let tab = open("https://work.example/", on: a, space: work)
        a.state.windows[a.window]?.profile = .defaultProfile
        settle([a, b])
        XCTAssertNotNil(b.state.tabs[tab])
        a.state.deleteProfile(work)
        settle([a, b])
        XCTAssertNil(b.state.profiles[work])
        XCTAssertNil(b.state.tabs[tab])
    }

    func testBuiltinBackgroundSyncsAsEffect() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        a.state.profiles[.defaultProfile]?.imageInfo = SpaceImageInfo(fileName: "x.jpg", tint: HSBA(hue: 0, saturation: 0, brightness: 0, alpha: 1), prefersDarkUI: true, mode: .blur, builtinID: "ocean")
        settle([a, b])
        // (Nothing here performs the effect, so later rounds retry it.)
        XCTAssertFalse(b.source.effects.isEmpty)
        XCTAssertTrue(b.source.effects.allSatisfy { $0 == .setBuiltinBackground(.defaultProfile, builtinID: "ocean", mode: .blur) })
    }

    // MARK: - Favorites, folders, splits

    func testFavoritesAndFolders() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let fav = Tab(id: .assign(), panes: [Pane(id: .assign(), info: .init(url: URL(string: "https://fav.example/")!))])
        a.state.insertTab(fav, intoProfileFavoritesAtIndex: 0, profile: .defaultProfile)
        var folder = Tab.newFolderTab(name: "Reading")
        folder.folder?.tabs = []
        a.state.insertTab(folder, location: .ordinaryTabs(0), inWindow: a.window)
        let member = Tab(id: .assign(), panes: [Pane(id: .assign(), info: .init(url: URL(string: "https://member.example/")!))])
        a.state.insertTab(member, location: .folder(folder.id, 0), inWindow: a.window)
        settle([a, b])

        XCTAssertEqual(b.state.profiles[.defaultProfile]?.manualFavorites, [fav.id])
        XCTAssertEqual(b.pane(fav.id)?.baseInfo?.url?.absoluteString, "https://fav.example/", "favorites keep their pinned state")
        XCTAssertEqual(b.state.tabs[folder.id]?.folder?.name, "Reading")
        XCTAssertEqual(b.state.tabs[folder.id]?.folder?.tabs, [member.id])
        assertSameSyncedState(a, b)

        // Rename the folder on B, move the member out to the tab list.
        b.state.modifyFolder(id: folder.id) { $0.name = "Later"; $0.tabs = [] }
        b.state.windows[b.window]!.perProfileData[.defaultProfile]!.tabs.append(member.id)
        settle([a, b])
        XCTAssertEqual(a.state.tabs[folder.id]?.folder?.name, "Later")
        XCTAssertEqual(a.state.tabs[folder.id]?.folder?.tabs, [])
        XCTAssertTrue(a.tabs().contains(member.id))
        assertSameSyncedState(a, b)
    }

    func testSplitPanes() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let left = open("https://left.example/", on: a)
        let right = open("https://right.example/", on: a)
        settle([a, b])
        let rightPane = a.state.tabs[right]!.panes.first!.id
        a.state.moveToSplitView(sourceTabId: right, sourcePaneId: rightPane, destinationTabId: left)
        settle([a, b])
        XCTAssertEqual(b.state.tabs[left]?.panes.map(\.id), a.state.tabs[left]?.panes.map(\.id))
        XCTAssertEqual(b.state.tabs[left]?.panes.count, 2)
        XCTAssertNil(b.state.tabs[right])
        XCTAssertEqual(b.state.paneToTabMapping[rightPane], left)
        assertSameSyncedState(a, b)

        a.state.separateSplitTabs(tabId: left)
        settle([a, b])
        assertSameSyncedState(a, b)
        XCTAssertEqual(b.tabs().count, 2)
    }

    // MARK: - Scope

    func testOnlyPrimaryWindowTabsSync() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let mainTab = open("https://main.example/", on: a)
        settle([a, b])
        let primary = a.window
        XCTAssertEqual(a.state.sync?.primaryWindowID, primary, "pinned on first apply")
        // A second, newer window with its own tab.
        var w2 = a.state.newWindow()
        w2.lastActive = Date().addingTimeInterval(100)
        a.state.windows[w2.id] = w2
        let other = a.state.openTab(url: URL(string: "https://other.example/")!, activate: false, windowID: w2.id).id
        settle([a, b])
        XCTAssertEqual(a.state.syncPrimaryWindow?.id, primary, "stays on the pinned window")
        XCTAssertNil(b.state.tabs[other])
        XCTAssertEqual(b.tabs(), [mainTab])
    }

    func testNoWindowMeansNoProjection() {
        var s = BrowserState.defaultState
        XCTAssertNil(s.syncProjection())
        _ = s.newWindow()
        XCTAssertNotNil(s.syncProjection())
    }

    func testProjectionIsDeterministic() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub)
        for i in 0..<5 { open("https://\(i).example/", on: a) }
        XCTAssertEqual(a.state.syncProjection(), a.state.syncProjection())
    }

    // MARK: - Concurrency

    func testConcurrentRenameAndReorderBothSurvive() {
        let hub = makeHub()
        let a = makeDevice("A", hub: hub), b = makeDevice("B", hub: hub)
        let ids = ["1", "2", "3"].map { open("https://\($0).example/", on: a) }
        settle([a, b])
        a.state.modifyTab(id: ids[0]) { $0.customTitle = "Renamed on A" }
        b.state.windows[b.window]!.perProfileData[.defaultProfile]!.tabs = [ids[2], ids[1], ids[0]]
        a.engine.runUntilQuiet(); b.engine.runUntilQuiet()
        settle([a, b])
        XCTAssertEqual(a.state.tabs[ids[0]]?.customTitle, "Renamed on A")
        XCTAssertEqual(b.state.tabs[ids[0]]?.customTitle, "Renamed on A")
        XCTAssertEqual(a.tabs(), [ids[2], ids[1], ids[0]])
        assertSameSyncedState(a, b)
    }

    func testRandomizedBrowserConvergence() {
        for seed in UInt64(1)...UInt64(30) {
            var rng = SeededRandom(seed: seed)
            let hub = InMemorySyncHub(latency: 0...1.5, seed: seed, now: { [unowned self] in self.t })
            let devices = ["A", "B", "C"].map { makeDevice($0, hub: hub) }
            settle(devices)
            var spaces: [ID<Profile>] = [.defaultProfile]
            for step in 0..<50 {
                let d = devices.randomElement(using: &rng)!
                let space = spaces.randomElement(using: &rng)!
                let myTabs = d.tabs(space)
                switch Int.random(in: 0..<9, using: &rng) {
                case 0, 1:
                    open("https://s\(seed)-\(step).example/", on: d, space: spaces.randomElement(using: &rng)!)
                case 2:
                    if let tab = myTabs.randomElement(using: &rng) { navigate(tab, to: "https://nav\(step).example/", title: "T\(step)", on: d) }
                case 3:
                    if let tab = myTabs.randomElement(using: &rng), let pane = d.state.tabs[tab]?.panes.first?.id {
                        d.state._close(webContentId: pane, removeIfPinned: true)
                    }
                case 4:
                    if myTabs.count > 1 {
                        var list = myTabs
                        list.shuffle(using: &rng)
                        d.state.windows[d.window]!.perProfileData[space]!.tabs = list
                    }
                case 5:
                    if let tab = myTabs.randomElement(using: &rng) { d.state.modifyTab(id: tab) { $0.customTitle = "c\(step)" } }
                case 6:
                    if spaces.count < 3 {
                        let s = d.state.createNewProfile()
                        d.state.profiles[s]?.title = "Space \(step)"
                        spaces.append(s)
                    }
                case 7:
                    if let s = spaces.randomElement(using: &rng) { d.state.profiles[s]?.emoji = ["🍎", "🍐", "🍊"].randomElement(using: &rng) }
                default:
                    if myTabs.count >= 2, let src = myTabs.last, let dst = myTabs.first, let pane = d.state.tabs[src]?.panes.first?.id {
                        // Splits happen in the space the window is showing.
                        d.state.windows[d.window]?.profile = space
                        d.state.moveToSplitView(sourceTabId: src, sourcePaneId: pane, destinationTabId: dst)
                    }
                }
                if Bool.random(using: &rng) { d.engine.runUntilQuiet() }
                t = t.addingTimeInterval(Double.random(in: 0...0.5, using: &rng))
            }
            settle(devices, rounds: 8)
            for d in devices.dropFirst() {
                assertSameSyncedState(devices[0], d)
            }
            for d in devices {
                // Local invariants: every listed tab exists; pane lookup is consistent.
                for (pid, data) in d.state.windows[d.window]!.perProfileData {
                    for tab in data.tabs { XCTAssertNotNil(d.state.tabs[tab], "seed \(seed) space \(pid.raw)") }
                }
                for (paneID, tabID) in d.state.paneToTabMapping {
                    XCTAssertNotNil(d.state.tabs[tabID]?.panes[paneID], "seed \(seed): stale pane mapping")
                }
            }
        }
    }
}
