import XCTest
@testable import Core

#if os(macOS)
final class BrowserJSTests: XCTestCase {

    // MARK: - NativePageKey roundtrip

    func testNativePageKeyTerminalRoundtrip() {
        let key = NativePageKey.terminal(id: "abc-123", cwd: "/tmp")
        let url = key.url
        XCTAssertEqual(url.scheme, "about")
        let decoded = NativePageKey(url: url)
        XCTAssertEqual(decoded, key)
    }

    func testNativePageKeyVSCodeRoundtrip() {
        let key = NativePageKey.vscode(id: "vscode-1", folder: "/Users/me/proj")
        let decoded = NativePageKey(url: key.url)
        XCTAssertEqual(decoded, key)

        let bare = NativePageKey.vscode(id: "vscode-2", folder: nil)
        XCTAssertEqual(NativePageKey(url: bare.url), bare)
    }

    func testNativePageKeyFileBrowserRoundtrip() {
        let key = NativePageKey.fileBrowser(id: "files-1", path: "/Users/me/Documents")
        let decoded = NativePageKey(url: key.url)
        XCTAssertEqual(decoded, key)

        let bare = NativePageKey.fileBrowser(id: "files-2", path: nil)
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
}

// MARK: - Test doubles

private final class MockHost: BrowserJSHost, @unchecked Sendable {
    struct Tab { var id: String; var url: String?; var title: String?; var index: Int; var kind: String }

    let lock = NSLock()
    var tabs: [Tab] = []
    var nextID = 1
    let windowID = "win-mock"
    var evalImpl: ((String, String) -> Any?)?

    func tabsList(windowId: String?) async throws -> [BrowserJSTabInfo] {
        lock.lock(); defer { lock.unlock() }
        return tabs.enumerated().map { (idx, t) in
            BrowserJSTabInfo(id: t.id, windowId: windowID, url: t.url, title: t.title, index: idx, kind: t.kind)
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
