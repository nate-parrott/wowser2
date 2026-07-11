import XCTest
@testable import Core

#if os(macOS)
final class BrowserJSTests: XCTestCase {

    // MARK: - NativePageKey roundtrip

    func testNativePageKeyTerminalRoundtrip() {
        let key = NativePageKey.terminal(cwd: "/tmp")
        let url = key.url
        XCTAssertEqual(url.scheme, "about")
        let decoded = NativePageKey(url: url)
        XCTAssertEqual(decoded, key)
    }

    func testNativePageKeyVSCodeRoundtrip() {
        let key = NativePageKey.vscode(folder: "/Users/me/proj")
        let decoded = NativePageKey(url: key.url)
        XCTAssertEqual(decoded, key)

        let bare = NativePageKey.vscode(folder: nil)
        XCTAssertEqual(NativePageKey(url: bare.url), bare)
    }

    func testNativePageKeyFileBrowserRoundtrip() {
        let key = NativePageKey.fileBrowser(path: "/Users/me/Documents")
        let decoded = NativePageKey(url: key.url)
        XCTAssertEqual(decoded, key)

        let bare = NativePageKey.fileBrowser(path: nil)
        XCTAssertEqual(NativePageKey(url: bare.url), bare)
    }

    func testNativePageKeyDoesNotMatchPlainAboutBlank() {
        XCTAssertNil(NativePageKey(url: URL(string: "about:blank")!))
        XCTAssertNil(NativePageKey(url: URL(string: "about:blank?homepage=true")!))
        XCTAssertNil(NativePageKey(url: URL(string: "https://example.com/")!))
    }

    // MARK: - BrowserJS runtime

    func testReturnSimpleValue() async throws {
        let host = MockHost()
        let helpers = MemoryHelpers()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)
        let result = await rt.run(code: "return 1 + 2;")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "3")
    }

    func testTopLevelAwait() async throws {
        let host = MockHost()
        let helpers = MemoryHelpers()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)
        let result = await rt.run(code: "await browser.sleep(20); return 'ok';")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"ok\"")
    }

    func testBrowserLog() async throws {
        let host = MockHost()
        let helpers = MemoryHelpers()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)
        let result = await rt.run(code: "browser.log('hello', {x:1}); return 1;")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.logs, ["hello {\"x\":1}"])
    }

    func testTabsListAndOpen() async throws {
        let host = MockHost()
        let helpers = MemoryHelpers()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)

        let r1 = await rt.run(code: """
        const id = await browser.tabs.open('https://example.com');
        const list = await browser.tabs.list();
        return { id: id, count: list.length, urls: list.map(t => t.url) };
        """)
        XCTAssertNil(r1.error, r1.error ?? "")
        XCTAssertEqual(host.tabs.count, 1)
        XCTAssertEqual(host.tabs.first?.url, "https://example.com")
    }

    func testTabsOpenCloseList() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let r = await rt.run(code: """
        const a = await browser.tabs.open('https://a.com');
        const b = await browser.tabs.open('https://b.com');
        const before = (await browser.tabs.list()).length;
        await browser.tabs.close(a);
        const after = (await browser.tabs.list()).length;
        return [before, after];
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "[2,1]")
    }

    func testTabsActivateAndGet() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let r = await rt.run(code: """
        const id = await browser.tabs.open('https://x.com');
        await browser.tabs.activate(id);
        const info = await browser.tabs.get(id);
        return info.url;
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "\"https://x.com\"")
    }

    func testTabsMove() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let r = await rt.run(code: """
        const a = await browser.tabs.open('https://a');
        const b = await browser.tabs.open('https://b');
        const c = await browser.tabs.open('https://c');
        await browser.tabs.move(a, 2);
        const urls = (await browser.tabs.list()).map(t => t.url);
        return urls;
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "[\"https://b\",\"https://c\",\"https://a\"]")
    }

    func testNavigate() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let r = await rt.run(code: """
        const id = await browser.tabs.open('https://a.com');
        await browser.tabs.navigate(id, 'https://b.com');
        return (await browser.tabs.get(id)).url;
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "\"https://b.com\"")
    }

    func testPageEval() async throws {
        let host = MockHost()
        host.evalImpl = { _, js in
            if js.contains("return 1+1") { return 2 }
            return NSNull()
        }
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let r = await rt.run(code: """
        const id = await browser.tabs.open('https://x.com');
        const v = await browser.page.eval(id, 'return 1+1');
        return v;
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "2")
    }

    func testHelperPreambleConcatenated() async throws {
        let helpers = MemoryHelpers()
        try helpers.saveHelper(name: "math", content: "function double(x){ return x*2; }")
        try helpers.saveHelper(name: "greet", content: "function greet(){ return 'hi'; }")
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)
        let r = await rt.run(code: "return double(21) + ' ' + greet();")
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "\"42 hi\"")
    }

    func testHelpersAlphaOrder() async throws {
        let helpers = MemoryHelpers()
        // 'b' redefines x; if order is alpha (a → b), b wins; if reverse, a wins.
        try helpers.saveHelper(name: "a", content: "var __x__ = 1;")
        try helpers.saveHelper(name: "b", content: "var __x__ = 2;")
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: helpers)
        let r = await rt.run(code: "return __x__;")
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, "2")
    }

    func testRuntimeErrorIsReported() async throws {
        let rt = BrowserJSRuntime(host: MockHost(), helpers: MemoryHelpers())
        let r = await rt.run(code: "throw new Error('boom');")
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error!.contains("boom"), r.error ?? "")
    }

    func testCallToNotImplementedThrows() async throws {
        let rt = BrowserJSRuntime(host: MockHost(), helpers: MemoryHelpers())
        let r = await rt.run(code: "await browser.webapp.create({name:'x', html:'<h1>hi</h1>'});")
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error!.contains("not implemented"), r.error ?? "")
    }

    func testTimeout() async throws {
        var caps = BrowserJSRuntime.Caps()
        caps.timeoutSeconds = 0.2
        let rt = BrowserJSRuntime(host: MockHost(), helpers: MemoryHelpers(), caps: caps)
        let r = await rt.run(code: "await browser.sleep(2000); return 'late';")
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error!.lowercased().contains("timeout"), r.error ?? "")
    }

    func testResultTruncation() async throws {
        var caps = BrowserJSRuntime.Caps()
        caps.maxResultBytes = 100
        let rt = BrowserJSRuntime(host: MockHost(), helpers: MemoryHelpers(), caps: caps)
        let r = await rt.run(code: "return 'x'.repeat(1000);")
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertTrue(r.truncated)
        XCTAssertLessThanOrEqual(r.result?.utf8.count ?? 0, 100 + "...[truncated]".count)
    }

    // MARK: - Helpers store sanitation

    func testHelperRejectsBadNames() throws {
        let helpers = MemoryHelpers()
        XCTAssertThrowsError(try helpers.saveHelper(name: "../escape", content: "x"))
        XCTAssertThrowsError(try helpers.saveHelper(name: "with space", content: "x"))
        XCTAssertThrowsError(try helpers.saveHelper(name: "", content: "x"))
        XCTAssertNoThrow(try helpers.saveHelper(name: "good_name-1", content: "x"))
    }

    // MARK: - Docs

    func testDocsAreNonEmpty() {
        let dts = BrowserJSDocs.dts
        XCTAssertTrue(dts.contains("browser"))
        XCTAssertTrue(dts.contains("tabs.list") || dts.contains("tabs"))
    }

    // MARK: - Splits

    /// The shim must forward `besideTabId` and default `activate` to true —
    /// a dropped `besideTabId` would silently split the wrong tab.
    func testOpenSplitForwardsBesideTabIdAndDefaultsActivateTrue() async throws {
        let host = MockHost()
        _ = try await host.tabsOpen(url: "https://a.example", background: false, windowId: nil)
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        let result = await rt.run(code: "return await browser.tabs.openSplit('https://b.example', { besideTabId: 't1' });")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"pane2\"")
        XCTAssertEqual(host.openSplitCalls, [.init(url: "https://b.example", besideTabId: "t1", activate: true, windowId: nil)])
    }

    /// `activate: false` must survive the JS `!== false` coercion in the shim.
    func testOpenSplitActivateFalseIsForwarded() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let result = await rt.run(code: "return await browser.tabs.openSplit('https://b.example', { activate: false });")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(host.openSplitCalls.first?.activate, false)
    }

    /// Omitting opts entirely must still mean activate=true, besideTabId=nil.
    func testOpenSplitWithoutOptsDefaults() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let result = await rt.run(code: "return await browser.tabs.openSplit('https://b.example');")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(host.openSplitCalls, [.init(url: "https://b.example", besideTabId: nil, activate: true, windowId: nil)])
    }

    func testSplitsGetReturnsPaneIds() async throws {
        let host = MockHost()
        _ = try await host.tabsOpen(url: "https://a.example", background: false, windowId: nil)
        _ = try await host.tabsOpen(url: "https://b.example", background: false, windowId: nil)
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        let result = await rt.run(code: "var s = await browser.splits.get('t1'); return s.tabIds.join(',') + '|' + s.focusedTabId;")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"t1,t2|t1\"")
    }

    func testSplitsSeparatePreservesPaneIds() async throws {
        let host = MockHost()
        _ = try await host.tabsOpen(url: "https://a.example", background: false, windowId: nil)
        _ = try await host.tabsOpen(url: "https://b.example", background: false, windowId: nil)
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        let result = await rt.run(code: "return (await browser.splits.separate('t1')).join(',');")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"t1,t2\"")
    }

    func testSplitsGetUnknownTabThrowsIntoJS() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let result = await rt.run(code: "try { await browser.splits.get('nope'); return 'no-throw'; } catch (e) { return 'threw'; }")
        XCTAssertEqual(result.result, "\"threw\"")
    }

    // MARK: - Spaces

    func testSpacesListShapeAndOrder() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let result = await rt.run(code: "return (await browser.spaces.list()).map(function(s) { return s.index + ':' + s.displayName; }).join('|');")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"0:Work|1:Recipes|2:Space 3\"")
    }

    /// Hidden spaces are omitted by default — they aren't in the carousel.
    func testSpacesListHiddenOnlyWithIncludeHidden() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        let byDefault = await rt.run(code: "return (await browser.spaces.list()).length;")
        XCTAssertEqual(byDefault.result, "3")

        let including = await rt.run(code: "return (await browser.spaces.list({ includeHidden: true })).map(function(s) { return s.id; }).join(',');")
        XCTAssertEqual(including.result, "\"p0,p1,p2,p3\"")
    }

    func testSpacesGetCurrent() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())
        let result = await rt.run(code: "var s = await browser.spaces.getCurrent(); return s.id + ':' + s.emoji + ':' + s.isCurrent;")
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, "\"p0:💼:true\"")
    }

    func testSpacesActivateForwardsIdAndUnknownSpaceThrows() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        let ok = await rt.run(code: "await browser.spaces.activate('p1'); return 'ok';")
        XCTAssertNil(ok.error, ok.error ?? "")
        XCTAssertEqual(host.activatedSpaces, ["p1"])

        let bad = await rt.run(code: "try { await browser.spaces.activate('nope'); return 'no-throw'; } catch (e) { return 'threw'; }")
        XCTAssertEqual(bad.result, "\"threw\"")
        XCTAssertEqual(host.activatedSpaces, ["p1"], "failed activate must not be recorded")
    }

    /// `tabs.list({spaceId})` must reach the host — it's the only way to see a
    /// background space's tabs.
    func testTabsListForwardsSpaceId() async throws {
        let host = MockHost()
        let rt = BrowserJSRuntime(host: host, helpers: MemoryHelpers())

        _ = await rt.run(code: "return await browser.tabs.list({ spaceId: 'p1' });")
        XCTAssertEqual(host.lastTabsListSpaceId, "p1")

        _ = await rt.run(code: "return await browser.tabs.list();")
        XCTAssertNil(host.lastTabsListSpaceId, "omitting spaceId must mean 'the window's current space'")
    }

    func testDocsDescribeSplitsAndSpaces() {
        let dts = BrowserJSDocs.dts
        XCTAssertTrue(dts.contains("openSplit"))
        XCTAssertTrue(dts.contains("SpaceInfo"))
        XCTAssertTrue(dts.contains("SplitInfo"))
        XCTAssertTrue(dts.contains("splitTabIds"))
    }
}

// MARK: - Test doubles

private final class MockHost: BrowserJSHost, @unchecked Sendable {
    struct Tab { var id: String; var url: String?; var title: String?; var index: Int; var kind: String }

    let lock = NSLock()
    var tabs: [Tab] = []
    var nextID = 1
    let windowID = "win-mock"
    var evalImpl: ((String, String) -> Any?)?

    func tabsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSTabInfo] {
        lock.lock(); defer { lock.unlock() }
        lastTabsListSpaceId = spaceId
        return tabs.enumerated().map { (idx, t) in
            BrowserJSTabInfo(id: t.id, windowId: windowID, url: t.url, title: t.title, index: idx, kind: t.kind,
                             splitId: "split-1", splitTabIds: tabs.map(\.id), isFocusedInSplit: idx == 0, spaceId: spaceId ?? "p0")
        }
    }
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = "t\(nextID)"; nextID += 1
        tabs.append(Tab(id: id, url: url, title: nil, index: tabs.count, kind: "web"))
        return id
    }
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String {
        return try await tabsOpen(url: url, background: true, windowId: windowId)
    }
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = "t\(nextID)"; nextID += 1
        tabs.append(Tab(id: id, url: "about:blank", title: title, index: tabs.count, kind: "web"))
        return id
    }
    func tabsClose(id: String) async throws {
        lock.lock(); defer { lock.unlock() }
        tabs.removeAll(where: { $0.id == id })
    }
    func tabsActivate(id: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard tabs.contains(where: { $0.id == id }) else { throw BrowserJSError.tabNotFound(id) }
    }
    func tabsMove(id: String, toIndex: Int) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let oldIdx = tabs.firstIndex(where: { $0.id == id }) else { throw BrowserJSError.tabNotFound(id) }
        let t = tabs.remove(at: oldIdx)
        let target = max(0, min(tabs.count, toIndex))
        tabs.insert(t, at: target)
    }
    func tabsGet(id: String) async throws -> BrowserJSTabInfo {
        lock.lock(); defer { lock.unlock() }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { throw BrowserJSError.tabNotFound(id) }
        let t = tabs[idx]
        return BrowserJSTabInfo(id: t.id, windowId: windowID, url: t.url, title: t.title, index: idx, kind: t.kind)
    }
    func tabsNavigate(id: String, url: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { throw BrowserJSError.tabNotFound(id) }
        tabs[idx].url = url
    }
    func contentRead(id: String, as kind: String) async throws -> String { "mock content (\(kind))" }
    func contentScreenshot(id: String) async throws -> BrowserJSImage {
        BrowserJSImage(mime: "image/png", data: "")
    }
    func pageEval(id: String, js: String) async throws -> Any? {
        if let impl = evalImpl { return impl(id, js) }
        return NSNull()
    }
    func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? { true }
    func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {}
    func pageType(id: String, text: String) async throws {}
    func pageKey(id: String, key: String, modifiers: [String]) async throws {}
    func pageScroll(id: String, dx: Double, dy: Double) async throws {}
    func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary] { [] }
    func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary] { [] }
    func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse {
        NetFetchResponse(status: 200, headers: [:], body: "")
    }
    func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse {
        NetFetchResponse(status: 200, headers: [:], body: "")
    }
    func netCaptureOrigin(origin: String, enabled: Bool) async throws {}
    func windowsList() async throws -> [BrowserJSWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return [BrowserJSWindowInfo(id: windowID, tabIds: tabs.map(\.id), currentTabId: tabs.first?.id)]
    }
    func windowsGetCurrent() async throws -> BrowserJSWindowInfo? {
        try await windowsList().first
    }
    func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? {
        try await windowsList().first(where: { $0.id == id })
    }

    // MARK: Splits & spaces

    /// Records the args the JS shim actually forwarded, so tests can assert on them.
    struct OpenSplitCall: Equatable { var url: String; var besideTabId: String?; var activate: Bool; var windowId: String? }
    var openSplitCalls: [OpenSplitCall] = []
    var lastTabsListSpaceId: String?
    var separatedTabIds: [String] = []
    var activatedSpaces: [String] = []

    func tabsOpenSplit(url: String, besideTabId: String?, activate: Bool, windowId: String?) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        openSplitCalls.append(.init(url: url, besideTabId: besideTabId, activate: activate, windowId: windowId))
        let id = "pane\(nextID)"; nextID += 1
        tabs.append(Tab(id: id, url: url, title: nil, index: tabs.count, kind: "web"))
        return id
    }

    func splitsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSSplitInfo] {
        lock.lock(); defer { lock.unlock() }
        return [BrowserJSSplitInfo(id: "split-1", windowId: windowID, spaceId: "p0", index: 0,
                                   tabIds: tabs.map(\.id), focusedTabId: tabs.first?.id, title: "Split")]
    }
    func splitsGet(tabId: String) async throws -> BrowserJSSplitInfo {
        lock.lock(); defer { lock.unlock() }
        guard tabs.contains(where: { $0.id == tabId }) else { throw BrowserJSError.tabNotFound(tabId) }
        return BrowserJSSplitInfo(id: "split-1", windowId: windowID, spaceId: "p0", index: 0,
                                  tabIds: tabs.map(\.id), focusedTabId: tabId, title: "Split")
    }
    func splitsSeparate(tabId: String) async throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard tabs.contains(where: { $0.id == tabId }) else { throw BrowserJSError.tabNotFound(tabId) }
        separatedTabIds = tabs.map(\.id)
        return separatedTabIds
    }

    func spacesList(windowId: String?, includeHidden: Bool) async throws -> [BrowserJSSpaceInfo] {
        var out = [
            BrowserJSSpaceInfo(id: "p0", title: "Work", displayName: "Work", emoji: "💼", index: 0, isCurrent: true, windowIds: [windowID]),
            BrowserJSSpaceInfo(id: "p1", autoTitle: "Recipes", displayName: "Recipes", index: 1),
            // No title and no autoTitle → displayName falls back to "Space N".
            BrowserJSSpaceInfo(id: "p2", displayName: "Space 3", index: 2),
        ]
        if includeHidden {
            out.append(BrowserJSSpaceInfo(id: "p3", title: "Old", displayName: "Old", index: 3, hidden: true))
        }
        return out
    }
    func spacesGetCurrent(windowId: String?) async throws -> BrowserJSSpaceInfo? {
        try await spacesList(windowId: windowId, includeHidden: false).first(where: \.isCurrent)
    }
    func spacesActivate(spaceId: String, windowId: String?) async throws {
        lock.lock(); defer { lock.unlock() }
        guard ["p0", "p1", "p2"].contains(spaceId) else { throw BrowserJSError.spaceNotFound(spaceId) }
        activatedSpaces.append(spaceId)
    }
}

private final class MemoryHelpers: BrowserJSHelpersProvider, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func saveHelper(name: String, content: String) throws {
        try sanitize(name: name)
        lock.lock(); defer { lock.unlock() }
        store[name] = content
    }
    func readHelper(name: String) throws -> String? {
        try sanitize(name: name)
        lock.lock(); defer { lock.unlock() }
        return store[name]
    }
    func listHelpers() throws -> [(name: String, content: String)] {
        lock.lock(); defer { lock.unlock() }
        return store.keys.sorted().map { ($0, store[$0]!) }
    }
    func concatenatedHelpers() throws -> String {
        try listHelpers().map { "// helper: \($0.name)\n\($0.content)\n" }.joined(separator: "\n")
    }

    private func sanitize(name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw NSError(domain: "MemoryHelpers", code: 1)
        }
    }
}
#endif
