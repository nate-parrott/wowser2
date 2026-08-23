#if os(macOS)
import XCTest
import WebKit
@testable import Core

/// A detached WKWebView has a 0×0 viewport and can't be snapshotted. Parking it
/// in `AgentStageWindow` must give it a real viewport, a renderable layer tree,
/// and working native (NSEvent) input — the basis for driving ghost tabs.
@MainActor
final class AgentStageWindowTests: XCTestCase {

    private var webview: WKWebView!

    override func setUp() async throws {
        webview = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let url = try fixtureURL(named: "computer_use.html")
        webview.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await waitForPredicate("typeof window.__clicks === 'number'")
    }

    override func tearDown() async throws {
        AgentStageWindow.shared.unmount(webview)
        webview = nil
    }

    func testDetachedViewportIsZero() async throws {
        let w = try await readInt("innerWidth")
        XCTAssertEqual(w, 0)
    }

    func testStagingGivesRealViewportAndSnapshot() async throws {
        XCTAssertTrue(AgentStageWindow.shared.ensureRenderable(webview))
        XCTAssertTrue(AgentStageWindow.shared.contains(webview))
        XCTAssertNotNil(webview.window)
        try await waitForPredicate("innerWidth === \(Int(AgentStageWindow.viewportSize.width))")

        try await Task.sleep(nanoseconds: 300_000_000)
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        let img = try await webview.takeSnapshot(configuration: cfg)
        XCTAssertGreaterThan(img.size.width, 0)
        XCTAssertGreaterThan(img.size.height, 0)
    }

    func testNativeClickAndTypeOnStagedView() async throws {
        AgentStageWindow.shared.ensureRenderable(webview)
        try await waitForPredicate("innerWidth > 0")
        let before = try await readInt("window.__clicks")
        // The fixture's click target sits at (100, 70) — same spot the DOM
        // dispatcher tests use. Here it goes through a real NSEvent.
        BrowserJSInputDispatcher.click(in: webview, x: 100, y: 70, button: "left", clickCount: 1)
        try await waitForPredicate("window.__clicks === \(before + 1)")

        // Native typing: click into the input, then send keystrokes.
        let rect = try await eval("document.getElementById('text').getBoundingClientRect().toJSON()") as? [String: Any]
        let x = (rect?["x"] as? Double ?? 0) + 5, y = (rect?["y"] as? Double ?? 0) + 5
        BrowserJSInputDispatcher.click(in: webview, x: x, y: y, button: "left", clickCount: 1)
        try await waitForPredicate("document.activeElement && document.activeElement.id === 'text'")
        BrowserJSInputDispatcher.type(in: webview, text: "hey")
        try await waitForPredicate("document.getElementById('text').value === 'hey'")
        // Cmd+A routes to the selectAll: responder action.
        BrowserJSInputDispatcher.key(in: webview, key: "a", modifiers: ["command"])
        try await waitForPredicate("document.getElementById('text').selectionStart === 0 && document.getElementById('text').selectionEnd === 3")
    }

    func testUnmountDetaches() async throws {
        AgentStageWindow.shared.ensureRenderable(webview)
        AgentStageWindow.shared.unmount(webview)
        XCTAssertNil(webview.window)
        XCTAssertFalse(AgentStageWindow.shared.contains(webview))
    }

    // MARK: - Helpers (mirror BrowserJSInputDispatcherTests)

    private func fixtureURL(named name: String) throws -> URL {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = here.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing: \(url.path)") }
        return url
    }

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webview.evaluateJavaScript(js) { v, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: v) }
            }
        }
    }

    private func readInt(_ js: String) async throws -> Int {
        (try await eval(js) as? NSNumber)?.intValue ?? -1
    }

    private func waitForPredicate(_ js: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = try? await eval(js) as? Bool, v { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(js)")
    }
}
#endif
