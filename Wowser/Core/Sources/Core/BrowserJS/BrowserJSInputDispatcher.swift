#if os(macOS)
import AppKit
import Foundation
import WebKit

/// Synthesizes computer-use inputs (click, type, key, scroll) into a
/// `WKWebView`.
///
/// Two strategies:
///
/// 1. **Native** (preferred): build real `NSEvent`s and hand them straight to
///    the webview's `mouseDown(with:)` / `keyDown(with:)` etc. These go through
///    WebKit's own hit testing, focus handling, `:active`/`:hover`, pointer
///    events, IME, and — crucially — default actions (Enter submits a form,
///    Tab moves focus, clicking a link navigates, React/Vue handlers fire).
///    Requires the view to be in a window; background tabs get one via
///    `AgentStageWindow`, so this is the path agents normally take. The window
///    does not need to be key or on screen.
///
/// 2. **DOM fallback**: dispatch JS-level events inside the page. Used only
///    when the webview has no window at all (e.g. unit tests). Covers event
///    listeners but not browser default actions.
@MainActor
enum BrowserJSInputDispatcher {

    // MARK: - Click

    static func click(in webview: WKWebView, x: CGFloat, y: CGFloat, button: String, clickCount: Int) {
        if webview.window != nil {
            nativeClick(in: webview, x: x, y: y, button: button, clickCount: max(1, clickCount))
        } else {
            domClick(in: webview, x: x, y: y, button: button, clickCount: max(1, clickCount))
        }
    }

    private static func nativeClick(in webview: WKWebView, x: CGFloat, y: CGFloat, button: String, clickCount: Int) {
        guard let window = webview.window else { return }
        prepareForInput(webview)
        // WKWebView is flipped, so (x, y) from the top-left are view coords.
        let winPoint = webview.convert(NSPoint(x: x, y: y), to: nil)
        let (downType, upType): (NSEvent.EventType, NSEvent.EventType) = {
            switch button.lowercased() {
            case "right", "secondary": return (.rightMouseDown, .rightMouseUp)
            case "middle": return (.otherMouseDown, .otherMouseUp)
            default: return (.leftMouseDown, .leftMouseUp)
            }
        }()

        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: winPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: nextEventNumber(), clickCount: clicks, pressure: type == downType ? 1 : 0
            )
        }

        // Hover first so :hover styles / mouseenter handlers see the pointer.
        if let move = event(.mouseMoved, clicks: 0) { webview.mouseMoved(with: move) }
        for i in 1...clickCount {
            guard let down = event(downType, clicks: i), let up = event(upType, clicks: i) else { continue }
            switch downType {
            case .rightMouseDown: webview.rightMouseDown(with: down); webview.rightMouseUp(with: up)
            case .otherMouseDown: webview.otherMouseDown(with: down); webview.otherMouseUp(with: up)
            default: webview.mouseDown(with: down); webview.mouseUp(with: up)
            }
        }
    }

    private static func domClick(in webview: WKWebView, x: CGFloat, y: CGFloat, button: String, clickCount: Int) {
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
            var clicks = \(clickCount);
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

    // MARK: - Type

    static func type(in webview: WKWebView, text: String) {
        if webview.window != nil {
            prepareForInput(webview)
            for ch in text {
                let s = String(ch)
                if s == "\n" {
                    sendNativeKey(to: webview, named: "Enter", modifiers: [])
                } else {
                    sendNativeKey(to: webview, characters: s, charactersIgnoringModifiers: s, keyCode: 0, modifiers: [])
                }
            }
        } else {
            domType(in: webview, text: text)
        }
    }

    private static func domType(in webview: WKWebView, text: String) {
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

    // MARK: - Key

    static func key(in webview: WKWebView, key: String, modifiers: [String]) {
        let flags = modifierFlags(from: modifiers)
        if webview.window != nil {
            prepareForInput(webview)
            sendNativeKey(to: webview, named: key, modifiers: flags)
        } else {
            domKey(in: webview, key: key, modifiers: modifiers)
        }
    }

    private static func domKey(in webview: WKWebView, key: String, modifiers: [String]) {
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

    // MARK: - Scroll

    static func scroll(in webview: WKWebView, dx: CGFloat, dy: CGFloat) {
        // JS scrolling works with or without a window and is deterministic;
        // native scroll-wheel NSEvents can't be constructed without CGEvent.
        let js = """
        (function() {
            window.scrollBy({ left: \(Self.jsNum(dx)), top: \(Self.jsNum(dy)), behavior: 'auto' });
            return true;
        })();
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Native key plumbing

    /// Named keys → (characters, virtual keyCode). Names follow the DOM
    /// `KeyboardEvent.key` vocabulary, with a few aliases.
    private static let namedKeys: [String: (chars: String, code: UInt16)] = {
        func fk(_ u: Int) -> String { String(UnicodeScalar(u)!) }
        var m: [String: (String, UInt16)] = [
            "enter": ("\r", 36), "return": ("\r", 36),
            "tab": ("\t", 48),
            "escape": ("\u{1B}", 53), "esc": ("\u{1B}", 53),
            "backspace": ("\u{7F}", 51),
            "delete": (fk(NSDeleteFunctionKey), 117),
            "space": (" ", 49), " ": (" ", 49),
            "arrowup": (fk(NSUpArrowFunctionKey), 126), "up": (fk(NSUpArrowFunctionKey), 126),
            "arrowdown": (fk(NSDownArrowFunctionKey), 125), "down": (fk(NSDownArrowFunctionKey), 125),
            "arrowleft": (fk(NSLeftArrowFunctionKey), 123), "left": (fk(NSLeftArrowFunctionKey), 123),
            "arrowright": (fk(NSRightArrowFunctionKey), 124), "right": (fk(NSRightArrowFunctionKey), 124),
            "home": (fk(NSHomeFunctionKey), 115), "end": (fk(NSEndFunctionKey), 119),
            "pageup": (fk(NSPageUpFunctionKey), 116), "pagedown": (fk(NSPageDownFunctionKey), 121),
        ]
        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fCodes.enumerated() {
            m["f\(i + 1)"] = (fk(NSF1FunctionKey + i), code)
        }
        return m
    }()

    /// Cmd-shortcuts that are really editing *actions*. With a key window AppKit
    /// would route these through the Edit menu to the responder chain; there's
    /// no key window for a staged tab, so invoke the responder action on the
    /// webview directly — it forwards to the web process editor just like the
    /// menu item does.
    private static let editingShortcuts: [String: String] = [
        "a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:", "z": "undo:",
    ]

    private static func sendNativeKey(to webview: WKWebView, named key: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) {
            let lower = key.lowercased()
            let action: String? = (lower == "z" && modifiers.contains(.shift)) ? "redo:" : editingShortcuts[lower]
            if let action, webview.responds(to: NSSelectorFromString(action)) {
                _ = webview.perform(NSSelectorFromString(action), with: nil)
                return
            }
        }
        if let named = namedKeys[key.lowercased()] {
            sendNativeKey(to: webview, characters: named.chars, charactersIgnoringModifiers: named.chars, keyCode: named.code, modifiers: modifiers)
        } else {
            // A printable key, e.g. "a" or "A" or "/" — possibly with modifiers
            // (Cmd+A). Uppercase letters imply shift.
            var flags = modifiers
            if key.count == 1, key != key.lowercased() { flags.insert(.shift) }
            sendNativeKey(to: webview, characters: key, charactersIgnoringModifiers: key.lowercased(), keyCode: 0, modifiers: flags)
        }
    }

    private static func sendNativeKey(to webview: WKWebView, characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let window = webview.window else { return }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
                isARepeat: false, keyCode: keyCode
            )
        }
        if let down = make(.keyDown) {
            // Shortcuts (Cmd+A, Cmd+C, …) normally reach a view through
            // `performKeyEquivalent` before `keyDown`; WebKit handles editing
            // commands there. Mirror AppKit's order.
            let isShortcut = !modifiers.intersection([.command, .control]).isEmpty
            if !(isShortcut && webview.performKeyEquivalent(with: down)) {
                webview.keyDown(with: down)
            }
        }
        if let up = make(.keyUp) { webview.keyUp(with: up) }
    }

    private static func modifierFlags(from modifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "option", "alt": flags.insert(.option)
            case "command", "cmd", "meta": flags.insert(.command)
            default: break
            }
        }
        return flags
    }

    /// Make the webview first responder when it lives in the offscreen stage,
    /// so WebKit has an input context and treats the page as focused. Never
    /// touches first responder in a real window — that would steal focus from
    /// whatever the user is typing into.
    private static func prepareForInput(_ webview: WKWebView) {
        guard let window = webview.window, AgentStageWindow.shared.contains(webview) else { return }
        if window.firstResponder !== webview {
            window.makeFirstResponder(webview)
        }
    }

    private static var eventCounter = 1
    private static func nextEventNumber() -> Int {
        eventCounter += 1
        return eventCounter
    }

    private static func jsNum(_ v: CGFloat) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        return String(format: "%.2f", Double(v))
    }
}
#endif
