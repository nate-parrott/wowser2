import XCTest
import WebKit
@testable import Core

final class ElementPickerTests: XCTestCase {

    // MARK: - State

    func testStartAndCancelSelectorPicker() {
        var state = BrowserState.defaultState
        let windowID = state.newWindow().id
        let tab = Tab.newTabWithURL(URL(string: "https://example.com")!)
        state.insertTab(tab, location: .ordinaryTabs(0), inWindow: windowID)
        let pane = tab.panes[0]!

        XCTAssertFalse(state.cancelSelectorPicker(windowID: windowID), "nothing to cancel yet")

        state.startSelectorPicker(tabID: tab.id, mode: .augmented)
        XCTAssertEqual(state.windows[windowID]?.selectorPicker, SelectorPickerSession(paneId: pane.id, mode: .augmented))

        XCTAssertTrue(state.cancelSelectorPicker(windowID: windowID))
        XCTAssertNil(state.windows[windowID]?.selectorPicker)

        // Unknown tab is a no-op
        state.startSelectorPicker(tabID: Core.ID<Tab>.assign(), mode: .normal)
        XCTAssertNil(state.windows[windowID]?.selectorPicker)
    }

    // MARK: - AugmentedSelector JS generation

    func testPlainSelectorUsesHotPath() {
        let js = AugmentedSelector.matchesJS(for: "div#a > .b")
        XCTAssertTrue(js.contains("document.querySelectorAll(\"div#a > .b\")"))
        XCTAssertFalse(js.contains("__sss_resolve"))
    }

    func testAugmentedSelectorInlinesResolver() {
        XCTAssertTrue(AugmentedSelector.containsStyleSelectors(".__sss__bg__#fff"))
        XCTAssertFalse(AugmentedSelector.containsStyleSelectors("div.__sss"))
        let js = AugmentedSelector.matchesJS(for: "div > .__sss__bg__#fff")
        XCTAssertTrue(js.contains("window.__sss_resolve("))
        XCTAssertFalse(AugmentedSelector.resolverSource.isEmpty)
        XCTAssertTrue(AugmentedSelector.resolverSource.contains("__sss_resolve"))
    }

    // MARK: - End-to-end through a real WKWebView

    private static let html = """
    <!doctype html><html><head><style>
      body { margin: 0; }
      .hero { color: rgb(0, 0, 255); font-weight: 500; font-size: 72px; font-family: "Comic Sans MS", cursive; }
      .plain { font-size: 16px; }
      .boxed { background-color: rgb(255, 0, 0); border: 2px solid rgb(0, 0, 0); width: 50px; height: 30px; }
    </style></head><body>
      <div id="49487341" class="hero" style="position:absolute;left:0;top:0;height:90px;width:400px">First</div>
      <div class="hero" style="position:absolute;left:0;top:100px;height:90px;width:400px">Second</div>
      <div class="plain" style="position:absolute;left:0;top:200px;height:20px;width:400px">Plain</div>
      <div class="boxed" style="position:absolute;left:0;top:230px"></div>
      <div class="boxed" style="position:absolute;left:100px;top:230px"></div>
      <div class="boxed" style="position:absolute;left:200px;top:230px"></div>
    </body></html>
    """

    @MainActor
    private func loadedWebView(html: String = ElementPickerTests.html, readyCheck: String = "document.getElementById('49487341') !== null") async throws -> WKWebView {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete' && (\(readyCheck))") as? Bool, ready {
                return webView
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("page never loaded")
        throw CancellationError()
    }

    // MARK: - Hashed class names

    /// x.com-style page: a timeline region whose rows are covered in `r-xxxxxx`
    /// atomic classes. The picked row carries `aria-labelledby`; selectors must
    /// lean on the aria attributes, never on the hashed classes.
    @MainActor
    func testHashedClassesNeverOutrankAttributes() async throws {
        let html = """
        <!doctype html><html><body style="margin:0">
        <div role="region"><div aria-label="Timeline: Your Home Timeline">
        <script>
          var seed = 7; function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed; }
          function cls() { var s = 'r-'; for (var j = 0; j < 6; j++) s += (rnd() % 36).toString(36); return s; }
          var out = '';
          for (var i = 0; i < 40; i++) {
            var target = i === 3;
            out += '<div class="' + cls() + ' ' + cls() + ' r-bcqeeo" style="height:20px"' + (target ? ' id="target" aria-labelledby="x"' : '') + '>row ' + i + '</div>';
          }
          document.write(out);
        </script>
        </div></div></body></html>
        """
        let webView = try await loadedWebView(html: html, readyCheck: "document.getElementById('target') !== null")
        let candidates = try await webView.selectors(atPoint: CGPoint(x: 10, y: 70), mode: .normal)
        XCTAssertFalse(candidates.isEmpty)
        let unique = candidates.filter { $0.matchCount == 1 }
        XCTAssertFalse(unique.isEmpty, "\(candidates.map { $0.selector })")
        XCTAssertFalse(unique.contains { $0.selector.contains(".r-") }, "hashed classes in unique candidates: \(unique.map { $0.selector })")
        XCTAssertTrue(unique.contains { $0.selector.contains("[aria-labelledby]") }, "\(unique.map { $0.selector })")
        XCTAssertEqual(candidates.first?.selector.contains(".r-"), false, "top candidate: \(candidates.first?.selector ?? "")")
    }

    // MARK: - :has() downward expansion

    @MainActor
    func testHasExpansionProducesSemanticSelector() async throws {
        let html = """
        <!doctype html><html><body style="margin:0">
          <style>h2,p{margin:0}</style><main>
            <div class="xq9zkp" style="height:80px"><h2>A</h2><p>a</p></div>
            <div class="xq9zkp" style="height:80px"><h2>B</h2><p>b</p></div>
            <div class="xq9zkp" style="height:80px"><h2>C</h2><p>c</p></div>
            <div class="xq9zkp" style="height:80px"><p>d</p></div>
            <div class="xq9zkp" style="height:80px"><p>e</p></div>
            <div id="marker"></div>
          </main>
        </body></html>
        """
        let webView = try await loadedWebView(html: html, readyCheck: "document.getElementById('marker') !== null")
        let candidates = try await webView.selectors(atPoint: CGPoint(x: 200, y: 70), mode: .normal)
        let selectors = candidates.map { $0.selector }
        let hasCandidates = candidates.filter { $0.selector.contains(":has(") }
        XCTAssertFalse(hasCandidates.isEmpty, "\(selectors)")
        XCTAssertTrue(hasCandidates.contains { $0.selector.hasSuffix("div:has(> h2)") && $0.matchCount == 3 }, "\(selectors)")
        // At most one :has per candidate, and never :has on a non-semantic child.
        for c in hasCandidates {
            XCTAssertEqual(c.selector.components(separatedBy: ":has(").count - 1, 1, c.selector)
            XCTAssertFalse(c.selector.contains(":has(> div)") || c.selector.contains(":has(div)"), c.selector)
        }
    }

    @MainActor
    func testNumericIDSelectorIsEscaped() async throws {
        let webView = try await loadedWebView()
        let candidates = try await webView.selectors(atPoint: CGPoint(x: 10, y: 10), mode: .normal)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.contains { $0.selector == "#\\34 9487341" && $0.matchCount == 1 }, "\(candidates.map { $0.selector })")
        XCTAssertFalse(candidates.contains { $0.selector.hasPrefix("__sss__") || $0.selector.contains(".__sss__") }, "normal mode must not emit style selectors")
        // Every candidate must be resolvable by the browser.
        for c in candidates {
            let rects = try await webView.positionsForElementsMatchingSelector(c.selector, filterToViewBounds: false)
            XCTAssertEqual(rects.count, c.matchCount, c.selector)
        }
    }

    @MainActor
    func testAugmentedModeGeneratesStyleSelectors() async throws {
        let webView = try await loadedWebView()
        let candidates = try await webView.selectors(atPoint: CGPoint(x: 10, y: 110), mode: .augmented)
        let selectors = candidates.map(\.selector)

        let textToken = ".__sss__text__#00f__500__72__Comic_Sans_MS"
        let fontToken = ".__sss__font__500__72__Comic_Sans_MS"
        XCTAssertTrue(selectors.contains(textToken), "\(selectors)")
        XCTAssertTrue(selectors.contains(fontToken), "\(selectors)")
        XCTAssertEqual(candidates.first { $0.selector == textToken }?.matchCount, 2)
        XCTAssertFalse(selectors.contains { $0.contains("__sss__bg__") || $0.contains("__sss__border__") }, "no background/border on the picked text")

        // Temporary classes are cleaned up afterwards.
        let leftover = try await webView.evaluateJavaScript("document.querySelectorAll('[class*=\"__sss__\"]').length") as? Int
        XCTAssertEqual(leftover, 0)
    }

    @MainActor
    func testAugmentedSelectorResolvesViaSwiftHelper() async throws {
        let webView = try await loadedWebView()

        // Resolve without the picker lib injected — the helper must be self-contained.
        let bgRects = try await webView.positionsForElementsMatchingSelector("div.__sss__bg__#f00", filterToViewBounds: false)
        XCTAssertEqual(bgRects.count, 3)

        let borderRects = try await webView.positionsForElementsMatchingSelector(".__sss__border__#000__2__none", filterToViewBounds: false)
        XCTAssertEqual(borderRects.count, 3)

        let textRects = try await webView.positionsForElementsMatchingSelector(".__sss__text__#00f__500__72__Comic_Sans_MS", filterToViewBounds: false)
        XCTAssertEqual(textRects.count, 2)

        let combined = try await webView.positionsForElementsMatchingSelector("body > .__sss__font__500__72__Comic_Sans_MS:first-child", filterToViewBounds: false)
        XCTAssertEqual(combined.count, 1)

        let none = try await webView.positionsForElementsMatchingSelector(".__sss__bg__#0f0", filterToViewBounds: false)
        XCTAssertEqual(none.count, 0)

        let leftover = try await webView.evaluateJavaScript("document.querySelectorAll('[class*=\"__sss__\"]').length") as? Int
        XCTAssertEqual(leftover, 0)
    }
}
