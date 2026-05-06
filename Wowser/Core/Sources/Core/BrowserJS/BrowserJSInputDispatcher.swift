#if os(macOS)
import Foundation
import WebKit

/// Synthesizes computer-use inputs (click, type, key, scroll) into a
/// `WKWebView` by dispatching JS-level events into the page. This works
/// regardless of whether the webview is in a key window — important because
/// agent-driven ghost tabs are not focused, and we want tests / background
/// automation to behave consistently.
///
/// The trade-off vs. `NSEvent` posting: native events drive WebKit's hit
/// testing, gesture machinery, and IME path; JS-dispatched events drive only
/// the DOM event listeners. For the agent's use cases (form fills, button
/// clicks, page scroll), DOM-level dispatch is sufficient and far more
/// deterministic.
@MainActor
enum BrowserJSInputDispatcher {
    static func click(in webview: WKWebView, x: CGFloat, y: CGFloat, button: String, clickCount: Int) {
        let buttonCode: Int = {
            switch button.lowercased() {
            case "right", "secondary": return 2
            case "middle": return 1
            default: return 0
            }
        }()
        let js = """
        (function() {
            var x = \(Self.jsNum(x));
            var y = \(Self.jsNum(y));
            var btn = \(buttonCode);
            var clicks = \(max(1, clickCount));
            var el = document.elementFromPoint(x, y);
            var target = el || document.body;
            function dispatch(type, count) {
                var ev = new MouseEvent(type, {
                    bubbles: true, cancelable: true, composed: true,
                    clientX: x, clientY: y, button: btn, buttons: btn === 0 ? 1 : (btn === 2 ? 2 : 4),
                    detail: count
                });
                target.dispatchEvent(ev);
            }
            for (var i = 1; i <= clicks; i++) {
                dispatch('mousedown', i);
                dispatch('mouseup', i);
                dispatch('click', i);
            }
            if (clicks === 2) dispatch('dblclick', 2);
            if (btn === 2) {
                var ctx = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y });
                target.dispatchEvent(ctx);
            }
            try { if (target && target.focus) target.focus(); } catch (_) {}
            return true;
        })();
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    static func type(in webview: WKWebView, text: String) {
        // Encode as JSON string literal so we don't have to escape ourselves.
        let lit = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let js = """
        (function() {
            var s = \(lit);
            var el = document.activeElement || document.body;
            for (var i = 0; i < s.length; i++) {
                var ch = s.charAt(i);
                var keydown = new KeyboardEvent('keydown', { key: ch, bubbles: true, cancelable: true });
                el.dispatchEvent(keydown);
                if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
                    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                        var setter = Object.getOwnPropertyDescriptor(window[el.tagName === 'INPUT' ? 'HTMLInputElement' : 'HTMLTextAreaElement'].prototype, 'value').set;
                        setter.call(el, (el.value || '') + ch);
                    } else {
                        document.execCommand('insertText', false, ch);
                    }
                    var input = new InputEvent('input', { bubbles: true, cancelable: false, data: ch, inputType: 'insertText' });
                    el.dispatchEvent(input);
                }
                var keyup = new KeyboardEvent('keyup', { key: ch, bubbles: true, cancelable: true });
                el.dispatchEvent(keyup);
            }
            return true;
        })();
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    static func key(in webview: WKWebView, key: String, modifiers: [String]) {
        let lit = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let mods = modifiers.map { $0.lowercased() }
        let shift = mods.contains("shift")
        let ctrl = mods.contains("control") || mods.contains("ctrl")
        let alt = mods.contains("option") || mods.contains("alt")
        let meta = mods.contains("command") || mods.contains("cmd") || mods.contains("meta")
        let js = """
        (function() {
            var k = \(lit);
            var el = document.activeElement || document.body;
            var init = { key: k, bubbles: true, cancelable: true,
                shiftKey: \(shift), ctrlKey: \(ctrl), altKey: \(alt), metaKey: \(meta) };
            el.dispatchEvent(new KeyboardEvent('keydown', init));
            el.dispatchEvent(new KeyboardEvent('keyup', init));
            return true;
        })();
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    static func scroll(in webview: WKWebView, dx: CGFloat, dy: CGFloat) {
        let js = """
        (function() {
            window.scrollBy({ left: \(Self.jsNum(dx)), top: \(Self.jsNum(dy)), behavior: 'auto' });
            return true;
        })();
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsNum(_ v: CGFloat) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        return String(format: "%.2f", Double(v))
    }
}
#endif
