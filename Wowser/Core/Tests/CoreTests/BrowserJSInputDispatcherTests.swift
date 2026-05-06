#if os(macOS)
import XCTest
import WebKit
@testable import Core

/// Loads the local file:// fixture into a real WKWebView and exercises
/// `BrowserJSInputDispatcher` to verify the click/type/scroll/key code paths
/// actually drive the page's DOM event listeners.
@MainActor
final class BrowserJSInputDispatcherTests: XCTestCase {

    private var webview: WKWebView!

    override func setUp() async throws {
        let cfg = WKWebViewConfiguration()
        webview = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        let url = try fixtureURL(named: "computer_use.html")
        webview.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await waitForPredicate("typeof window.__clicks === 'number'")
    }

    override func tearDown() async throws {
        webview = nil
    }

    func testClickIncrementsCounter() async throws {
        let before = try await readInt("window.__clicks")
        BrowserJSInputDispatcher.click(in: webview, x: 100, y: 70, button: "left", clickCount: 1)
        try await waitForPredicate("window.__clicks === \(before + 1)")
        let after = try await readInt("window.__clicks")
        XCTAssertEqual(after, before + 1)
    }

    func testTypeWritesIntoInput() async throws {
        // Focus the input field first.
        _ = try await eval("document.getElementById('text').focus(); true")
        BrowserJSInputDispatcher.type(in: webview, text: "hello")
        try await waitForPredicate("document.getElementById('text').value === 'hello'")
        let value = try await readString("document.getElementById('text').value")
        XCTAssertEqual(value, "hello")
        // The page mirrors the input value into #readout via 'input' events.
        let readout = try await readString("document.getElementById('readout').textContent")
        XCTAssertEqual(readout, "hello")
    }

    func testScrollMovesViewport() async throws {
        let before = try await readInt("window.scrollY")
        BrowserJSInputDispatcher.scroll(in: webview, dx: 0, dy: 400)
        try await waitForPredicate("window.scrollY > \(before)")
        let after = try await readInt("window.scrollY")
        XCTAssertGreaterThan(after, before)
    }

    func testKeyDispatchesToActiveElement() async throws {
        _ = try await eval("""
        window.__lastKey = null;
        document.getElementById('text').focus();
        document.getElementById('text').addEventListener('keydown', function(e) { window.__lastKey = e.key; });
        true
        """)
        BrowserJSInputDispatcher.key(in: webview, key: "Enter", modifiers: [])
        try await waitForPredicate("window.__lastKey === 'Enter'")
    }

    // MARK: - Helpers

    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "Fixtures/\(name)", withExtension: nil) {
            return url
        }
        // Fallback for nested resource layout.
        let stripped = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = bundle.url(forResource: stripped, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
    }

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webview.evaluateJavaScript(js) { value, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: value) }
            }
        }
    }

    private func readInt(_ expr: String) async throws -> Int {
        let v = try await eval("(\(expr))")
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        return 0
    }

    private func readString(_ expr: String) async throws -> String {
        let v = try await eval("(\(expr))")
        return v as? String ?? ""
    }

    private func waitForPredicate(_ expr: String, timeoutSeconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let val = try? await eval("!!(\(expr))") as? Bool, val { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("predicate never became true: \(expr)")
    }
}
#endif
