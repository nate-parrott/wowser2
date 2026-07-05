import XCTest
import WebKit
@testable import Core

#if os(macOS)
final class TangSchemeTests: XCTestCase {

    // MARK: - Slugging

    func testSlug() {
        XCTAssertEqual(TangerineApps.slug(for: "My Cool App"), "my-cool-app")
        XCTAssertEqual(TangerineApps.slug(for: "  Hello!!World  "), "hello-world")
        XCTAssertEqual(TangerineApps.slug(for: "Foo_Bar.baz"), "foo-bar-baz")
        XCTAssertEqual(TangerineApps.slug(for: "already-slugged"), "already-slugged")
        XCTAssertEqual(TangerineApps.slug(for: "***"), "app")
        XCTAssertEqual(TangerineApps.slug(for: ""), "app")
    }

    // MARK: - On-disk create / resolve

    private func tempApps() -> TangerineApps {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tang-tests-\(UUID().uuidString)", isDirectory: true)
        return TangerineApps(dir: dir)
    }

    func testCreateWritesFilesAndResolves() throws {
        let apps = tempApps()
        let slug = try apps.create(name: "Note Pad", files: [
            "index.html": "<h1>hi</h1>",
            "app.js": "console.log('x')",
            "sub/style.css": "body{}",
        ])
        XCTAssertEqual(slug, "note-pad")

        // index resolves (empty path defaults to index.html)
        let index = apps.resolveFile(forHost: slug, path: "/")
        XCTAssertNotNil(index)
        XCTAssertEqual(try String(contentsOf: index!, encoding: .utf8), "<h1>hi</h1>")

        // nested asset resolves
        let css = apps.resolveFile(forHost: slug, path: "/sub/style.css")
        XCTAssertEqual(try String(contentsOf: css!, encoding: .utf8), "body{}")

        XCTAssertTrue(apps.list().contains(slug))
    }

    func testCreateRequiresIndex() {
        let apps = tempApps()
        XCTAssertThrowsError(try apps.create(name: "no-index", files: ["main.js": "x"])) { err in
            guard case TangerineApps.TangError.missingIndex = err else {
                return XCTFail("expected missingIndex, got \(err)")
            }
        }
    }

    func testCreateOverwritesStaleFiles() throws {
        let apps = tempApps()
        _ = try apps.create(name: "app", files: ["index.html": "v1", "old.js": "old"])
        _ = try apps.create(name: "app", files: ["index.html": "v2"])
        XCTAssertEqual(try String(contentsOf: apps.resolveFile(forHost: "app", path: "/")!, encoding: .utf8), "v2")
        // stale file from the first create must be gone
        let stale = apps.resolveFile(forHost: "app", path: "/old.js")!
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testPathTraversalRejected() throws {
        let apps = tempApps()
        let slug = try apps.create(name: "secure", files: ["index.html": "ok"])
        XCTAssertNil(apps.resolveFile(forHost: slug, path: "/../../etc/passwd"))
        XCTAssertNil(apps.resolveFile(forHost: slug, path: "/../" + slug + "-other/index.html"))
        // a `..` segment inside create() must throw rather than escape
        XCTAssertThrowsError(try apps.create(name: "evil", files: [
            "index.html": "x",
            "../escape.txt": "nope",
        ]))
    }

    // MARK: - MIME

    func testMimeTypes() {
        XCTAssertEqual(TangSchemeHandler.mimeType(forExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(TangSchemeHandler.mimeType(forExtension: "JS"), "text/javascript; charset=utf-8")
        XCTAssertEqual(TangSchemeHandler.mimeType(forExtension: "css"), "text/css; charset=utf-8")
        XCTAssertEqual(TangSchemeHandler.mimeType(forExtension: "png"), "image/png")
        XCTAssertEqual(TangSchemeHandler.mimeType(forExtension: "zzz"), "application/octet-stream")
    }

    // MARK: - Dispatch routing

    func testDispatchRoutesWebappCreate() async throws {
        let host = TangMockHost()
        let args = #"{"name":"My App","files":{"index.html":"<h1>x</h1>","a.js":"1"},"exposeBrowserJS":true}"#
        let result = try await BrowserJSDispatch.handle(fn: "webapp.create", argsJSON: args, host: host)
        XCTAssertEqual(result, "\"webapp-tab-1\"")
        XCTAssertEqual(host.createdName, "My App")
        XCTAssertEqual(host.createdFiles?["index.html"], "<h1>x</h1>")
        XCTAssertEqual(host.createdFiles?["a.js"], "1")
    }

    // MARK: - End-to-end bridge through a real WKWebView

    @MainActor
    func testTangBridgeRoundTripThroughWebView() async throws {
        let apps = tempApps()
        // The page asks the native bridge for the tab list and stashes the
        // result in document.title so the test can read it back.
        let html = """
        <!doctype html><html><head><title>pending</title></head><body><script>
        (async function() {
            try {
                var tabs = await window.browser.tabs.list();
                document.title = 'OK:' + JSON.stringify(tabs);
            } catch (e) {
                document.title = 'ERR:' + ((e && e.message) || String(e));
            }
        })();
        </script></body></html>
        """
        _ = try apps.create(name: "probe", files: ["index.html": html])

        let host = TangMockHost()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(TangSchemeHandler(apps: apps), forURLScheme: TangSchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(TangBridge(host: host), contentWorld: .page, name: TangBridge.handlerName)
        config.userContentController.addUserScript(
            WKUserScript(source: TangBridge.userScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        )

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.load(URLRequest(url: URL(string: "tang://probe/")!))

        // Poll document.title until the page reports a result (or we time out).
        let title = try await pollTitle(webView, timeout: 8)
        XCTAssertTrue(title.hasPrefix("OK:"), "bridge round-trip failed, title=\(title)")
        XCTAssertTrue(title.contains(TangMockHost.fixedTabID), "expected tab id in result, title=\(title)")
    }

    @MainActor
    private func pollTitle(_ webView: WKWebView, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = try? await webView.evaluateJavaScript("document.title")
            if let t = value as? String, t.hasPrefix("OK:") || t.hasPrefix("ERR:") {
                return t
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return "TIMEOUT"
    }
}

// MARK: - Minimal host

/// A host that records webapp.create and returns a single fixed tab from
/// tabsList — enough to exercise dispatch + the web bridge round-trip.
private final class TangMockHost: BrowserJSHost, @unchecked Sendable {
    static let fixedTabID = "tab-fixed-123"

    var createdName: String?
    var createdFiles: [String: String]?

    func webappCreate(name: String, files: [String: String], exposeBrowserJS: Bool) async throws -> String {
        createdName = name
        createdFiles = files
        return "webapp-tab-1"
    }

    func tabsList(windowId: String?) async throws -> [BrowserJSTabInfo] {
        [BrowserJSTabInfo(id: Self.fixedTabID, windowId: "win-1", url: "tang://probe/", title: "Probe", index: 0, kind: "webapp")]
    }

    // Unused stubs.
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String { "t" }
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String { "t" }
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String { "t" }
    func tabsClose(id: String) async throws {}
    func tabsActivate(id: String) async throws {}
    func tabsMove(id: String, toIndex: Int) async throws {}
    func tabsGet(id: String) async throws -> BrowserJSTabInfo { BrowserJSTabInfo(id: id) }
    func tabsNavigate(id: String, url: String) async throws {}
    func contentRead(id: String, as kind: String) async throws -> String { "" }
    func contentScreenshot(id: String) async throws -> BrowserJSImage { BrowserJSImage(mime: "image/png", data: "") }
    func pageEval(id: String, js: String) async throws -> Any? { NSNull() }
    func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? { true }
    func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {}
    func pageType(id: String, text: String) async throws {}
    func pageKey(id: String, key: String, modifiers: [String]) async throws {}
    func pageScroll(id: String, dx: Double, dy: Double) async throws {}
    func windowsList() async throws -> [BrowserJSWindowInfo] { [] }
    func windowsGetCurrent() async throws -> BrowserJSWindowInfo? { nil }
    func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? { nil }
    func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary] { [] }
    func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary] { [] }
    func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse { NetFetchResponse(status: 200, headers: [:], body: "") }
    func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse { NetFetchResponse(status: 200, headers: [:], body: "") }
    func netCaptureOrigin(origin: String, enabled: Bool) async throws {}
}
#endif
