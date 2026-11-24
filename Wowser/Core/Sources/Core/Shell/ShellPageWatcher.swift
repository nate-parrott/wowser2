import Foundation
import WebKit

/// Observes things *inside* web pages for the scripted UI: "where is the
/// video element", "is anything playing", "what is selected".
///
/// A watch is a JavaScript expression evaluated in the page (in an isolated
/// world, so the page can't see or tamper with it). It is re-evaluated when
/// the document changes, scrolls or resizes — throttled — and its JSON value
/// is reported whenever it differs from the last one. Watches survive
/// navigation: they are re-installed when the pane finishes loading.
///
/// Used by `panes.watch()` / `useWatch()` in JS and by `<WebPane cropTo>`.
/// Main thread only.
final class ShellPageWatcher: NSObject, WKScriptMessageHandler {
    static let shared = ShellPageWatcher()

    static let handlerName = "wowserShellWatch"
    static let world = WKContentWorld.world(name: "WowserShell")

    private struct Watch {
        var paneID: ID<WebContent>
        var expression: String
        var throttleMs: Int
        var onChange: (ShellJSON) -> Void
    }

    private var watches: [String: Watch] = [:]
    private var nextID = 1
    /// Content controllers that already have our message handler (adding it
    /// twice raises).
    private let installed = NSHashTable<WKUserContentController>.weakObjects()

    /// Start watching. Returns an id for `unwatch`.
    @discardableResult
    func watch(paneID: ID<WebContent>, expression: String, throttleMs: Int = 100, onChange: @escaping (ShellJSON) -> Void) -> String {
        let id = "w\(nextID)"
        nextID += 1
        watches[id] = Watch(paneID: paneID, expression: expression, throttleMs: max(16, throttleMs), onChange: onChange)
        install(id)
        return id
    }

    func unwatch(_ id: String) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        webView(for: watch.paneID)?.evaluateJavaScript(
            "window.__wowserWatch && window.__wowserWatch[\(ShellJSON.quote(id))] && window.__wowserWatch[\(ShellJSON.quote(id))]()",
            in: nil, in: Self.world, completionHandler: nil
        )
    }

    /// A pane loaded a new document: its watches need installing again.
    func paneDidLoad(_ paneID: ID<WebContent>) {
        for (id, watch) in watches where watch.paneID == paneID { install(id) }
    }

    private func webView(for paneID: ID<WebContent>) -> WKWebView? {
        BrowserStore.shared.existingWebContent(forId: paneID)?.wkWebview
    }

    private func install(_ id: String) {
        guard let watch = watches[id], let webView = webView(for: watch.paneID) else { return }
        let controller = webView.configuration.userContentController
        if !installed.contains(controller) {
            controller.add(self, contentWorld: Self.world, name: Self.handlerName)
            installed.add(controller)
        }
        webView.evaluateJavaScript(Self.script(id: id, expression: watch.expression, throttleMs: watch.throttleMs), in: nil, in: Self.world, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String, let watch = watches[id] else { return }
        let value = (body["value"] as? String).flatMap { ShellJSON.parse($0) } ?? .null
        watch.onChange(value)
    }

    /// Installs one watch in the page. Evaluating it again replaces the
    /// previous install of the same id.
    private static func script(id: String, expression: String, throttleMs: Int) -> String {
        """
        (function () {
          var id = \(ShellJSON.quote(id));
          var registry = window.__wowserWatch = window.__wowserWatch || {};
          if (registry[id]) registry[id]();
          var compute;
          try { compute = new Function("return (" + \(ShellJSON.quote(expression)) + "\\n)"); }
          catch (e) { compute = function () { return { error: String(e) }; }; }
          var last, timer = 0, stopped = false;
          function check() {
            timer = 0;
            if (stopped) return;
            var value;
            try { value = JSON.stringify(compute()); } catch (e) { value = JSON.stringify({ error: String(e) }); }
            if (value === undefined) value = "null";
            if (value === last) return;
            last = value;
            window.webkit.messageHandlers.\(handlerName).postMessage({ id: id, value: value });
          }
          function schedule() { if (!timer) timer = setTimeout(check, \(throttleMs)); }
          var observer = new MutationObserver(schedule);
          observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
          var events = ["scroll", "resize", "selectionchange", "play", "pause", "ended", "volumechange", "fullscreenchange", "visibilitychange", "focusin", "focusout", "transitionend", "animationend", "load"];
          events.forEach(function (name) { (name === "resize" ? window : document).addEventListener(name, schedule, { capture: true, passive: true }); });
          // Layout can move things without any DOM event (fonts, images).
          var poll = setInterval(schedule, 1000);
          registry[id] = function () {
            stopped = true;
            observer.disconnect();
            clearInterval(poll);
            events.forEach(function (name) { (name === "resize" ? window : document).removeEventListener(name, schedule, { capture: true }); });
            delete registry[id];
          };
          check();
        })();
        """
    }

    /// The expression behind `<WebPane cropTo="selector">` and
    /// `useElementRect`: an element's box in viewport coordinates, plus the
    /// viewport size.
    static func elementRectExpression(selector: String) -> String {
        """
        (function () {
          var el = document.querySelector(\(ShellJSON.quote(selector)));
          if (!el) return null;
          var r = el.getBoundingClientRect();
          if (r.width < 1 || r.height < 1) return null;
          return { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height), viewportWidth: window.innerWidth, viewportHeight: window.innerHeight };
        })()
        """
    }
}
