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
///
/// Keyboard input never uses raw keyDowns (see `isolatedKey`). In editable
/// content WebKit hands keyDowns to the text input system, which delivers the
/// resulting text/commands to the *active* input context — the user's focused
/// view, e.g. their terminal, where a typed "\n" runs a command. And even
/// when nothing else has focus, keyDowns are processed asynchronously and get
/// reordered against the clicks that move focus, scattering text across
/// fields. So keys become a DOM keydown/keyup pair plus the equivalent WebCore
/// editing command (InsertText, DeleteBackward, MoveLeft, …), all addressed to
/// this webview only. Commands run through WebKit's
/// `_executeEditCommand:argument:completion:` SPI, which reports when each has
/// run so they stay in order; if that SPI ever disappears we fall back to the
/// webview's public `NSTextInputClient` / responder-action entry points.
@MainActor
enum BrowserJSInputDispatcher {

    // MARK: - Click

    /// Returns once the page has handled the click, so input that follows
    /// (typing into the field it focused) can't overtake it.
    static func click(in webview: WKWebView, x: CGFloat, y: CGFloat, button: String, clickCount: Int) async {
        if webview.window != nil {
            nativeClick(in: webview, x: x, y: y, button: button, clickCount: max(1, clickCount))
            await waitForPendingMouseEvents(in: webview)
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

    /// WebKit queues mouse events and sends each to the web process only once
    /// the previous one is acknowledged, while editing commands go straight
    /// through — so without this, text typed right after a click can land
    /// before the click has moved focus. Uses WebKit's
    /// `_doAfterProcessingAllPendingMouseEvents:` SPI; falls back to a JS
    /// round trip plus a short grace period.
    private static func waitForPendingMouseEvents(in webview: WKWebView) async {
        let sel = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        if webview.responds(to: sel), let imp = webview.method(for: sel) {
            typealias Action = @convention(block) () -> Void
            typealias Fn = @convention(c) (AnyObject, Selector, Action) -> Void
            let fn = unsafeBitCast(imp, to: Fn.self)
            await withCheckedContinuation { cont in fn(webview, sel) { cont.resume() } }
        } else {
            await evalJS(in: webview, "0")
            try? await Task.sleep(nanoseconds: 100_000_000)
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

    static func type(in webview: WKWebView, text: String) async {
        if webview.window != nil {
            for ch in text {
                await isolatedKey(in: webview, key: ch == "\n" ? "Enter" : String(ch), modifiers: [])
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

    static func key(in webview: WKWebView, key: String, modifiers: [String]) async {
        let flags = modifierFlags(from: modifiers)
        if let action = editingShortcutAction(key: key, modifiers: flags) {
            await performEditing(action, in: webview)
        } else if webview.window != nil {
            await isolatedKey(in: webview, key: key, modifiers: flags)
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

    // MARK: - Key tables

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
    /// would route these through the Edit menu to the responder chain; invoke
    /// the responder action on the webview directly instead — it forwards to
    /// the web process editor just like the menu item does.
    private static let editingShortcuts: [String: String] = [
        "a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:", "z": "undo:",
    ]

    private static func editingShortcutAction(key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        guard modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else { return nil }
        let lower = key.lowercased()
        return (lower == "z" && modifiers.contains(.shift)) ? "redo:" : editingShortcuts[lower]
    }

    // MARK: - Isolated keyboard input

    /// Editing actions (sent straight to the webview, like the Cmd shortcuts)
    /// standing in for named keys' default behaviour.
    private static func editingAction(forKey key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        let shift = modifiers.contains(.shift)
        let alt = modifiers.contains(.option)
        let cmd = modifiers.contains(.command)
        func sel(_ base: String) -> String { shift ? base + "AndModifySelection:" : base + ":" }
        switch key.lowercased() {
        case "backspace": return alt ? "deleteWordBackward:" : (cmd ? "deleteToBeginningOfLine:" : "deleteBackward:")
        case "delete": return alt ? "deleteWordForward:" : "deleteForward:"
        case "arrowleft", "left": return sel(cmd ? "moveToBeginningOfLine" : (alt ? "moveWordLeft" : "moveLeft"))
        case "arrowright", "right": return sel(cmd ? "moveToEndOfLine" : (alt ? "moveWordRight" : "moveRight"))
        case "arrowup", "up": return sel(cmd ? "moveToBeginningOfDocument" : "moveUp")
        case "arrowdown", "down": return sel(cmd ? "moveToEndOfDocument" : "moveDown")
        case "home": return sel("moveToBeginningOfLine")
        case "end": return sel("moveToEndOfLine")
        case "pageup": return "scrollPageUp:"
        case "pagedown": return "scrollPageDown:"
        default: return nil
        }
    }

    /// One key press without raw keyDowns: a DOM keydown (so page listeners
    /// run and can cancel it), then — unless cancelled — the key's effect
    /// applied to this webview only, then keyup.
    private static func isolatedKey(in webview: WKWebView, key: String, modifiers: NSEvent.ModifierFlags) async {
        let named = namedKeys[key.lowercased()]
        let domKey: String = {
            switch key.lowercased() {
            case "enter", "return": return "Enter"
            case "tab": return "Tab"
            case "escape", "esc": return "Escape"
            case "backspace": return "Backspace"
            case "delete": return "Delete"
            case "space", " ": return " "
            case "arrowup", "up": return "ArrowUp"
            case "arrowdown", "down": return "ArrowDown"
            case "arrowleft", "left": return "ArrowLeft"
            case "arrowright", "right": return "ArrowRight"
            case "home": return "Home"
            case "end": return "End"
            case "pageup": return "PageUp"
            case "pagedown": return "PageDown"
            default: return named == nil ? key : key.capitalized
            }
        }()
        let keyCode = named.map { Int(legacyKeyCode(forMacKeyCode: $0.code)) } ?? Int(key.uppercased().unicodeScalars.first?.value ?? 0)
        let cancelled = await dispatchDOMKey(in: webview, type: "keydown", key: domKey, keyCode: keyCode, modifiers: modifiers)
        if !cancelled {
            let isText = named == nil && key.count == 1
            let plainOrShift = modifiers.subtracting(.shift).intersection([.command, .control, .option]).isEmpty
            if (isText || domKey == " ") && plainOrShift {
                await insert(domKey == " " ? " " : key, in: webview)
            } else if domKey == "Enter", plainOrShift {
                await enterDefaultAction(in: webview)
            } else if domKey == "Tab" {
                await evalJS(in: webview, tabFocusJS(backward: modifiers.contains(.shift)))
            } else if let action = editingAction(forKey: key, modifiers: modifiers) {
                await performEditing(action, in: webview)
            }
        }
        _ = await dispatchDOMKey(in: webview, type: "keyup", key: domKey, keyCode: keyCode, modifiers: modifiers)
    }

    /// Enter: a newline in multi-line editors, implicit submission in forms.
    private static func enterDefaultAction(in webview: WKWebView) async {
        let multiline = await evalJS(in: webview, """
        (function() {
            var el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            if (!el) return false;
            if (el.tagName === 'TEXTAREA' || el.isContentEditable) return true;
            if (el.tagName === 'INPUT' && el.form) {
                if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
            } else if (el.tagName === 'BUTTON' || el.tagName === 'A' || el.getAttribute('role') === 'button') {
                el.click();
            }
            return false;
        })();
        """) as? Bool ?? false
        if multiline {
            await performEditing("insertNewline:", in: webview)
        }
    }

    // MARK: - Editing commands

    /// Inserts `text` at the page's selection.
    private static func insert(_ text: String, in webview: WKWebView) async {
        if await executeEditCommand("InsertText", argument: text, in: webview) == nil {
            webview.wowser_insertText(text)
        }
    }

    /// Runs the editing behind a responder action (e.g. "moveLeft:").
    private static func performEditing(_ action: String, in webview: WKWebView) async {
        if await executeEditCommand(editCommandName(forAction: action), argument: "", in: webview) == nil {
            let sel = NSSelectorFromString(action)
            if webview.responds(to: sel) { _ = webview.perform(sel, with: nil) }
        }
    }

    /// WebCore's command name for a responder action: "moveLeft:" → "MoveLeft".
    private static func editCommandName(forAction action: String) -> String {
        switch action {
        case "scrollPageUp:": return "ScrollPageBackward"
        case "scrollPageDown:": return "ScrollPageForward"
        default:
            let name = action.hasSuffix(":") ? String(action.dropLast()) : action
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Runs a WebCore editing command in the page through WebKit's
    /// `-[WKWebView _executeEditCommand:argument:completion:]` SPI and waits
    /// for it to finish. Returns nil when the SPI isn't available (callers
    /// fall back to public API), otherwise whether the command executed.
    private static func executeEditCommand(_ command: String, argument: String, in webview: WKWebView) async -> Bool? {
        let sel = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webview.responds(to: sel), let imp = webview.method(for: sel) else { return nil }
        typealias Completion = @convention(block) (ObjCBool) -> Void
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, NSString, Completion) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        return await withCheckedContinuation { cont in
            fn(webview, sel, command as NSString, argument as NSString) { ok in cont.resume(returning: ok.boolValue) }
        }
    }

    private static func tabFocusJS(backward: Bool) -> String {
        """
        (function() {
            var sel = 'a[href], area[href], button, input:not([type=hidden]), select, textarea, iframe, [tabindex], [contenteditable=""], [contenteditable=true]';
            var all = Array.prototype.filter.call(document.querySelectorAll(sel), function(el) {
                if (el.disabled || el.tabIndex < 0) return false;
                var r = el.getBoundingClientRect();
                return r.width > 0 || r.height > 0;
            });
            if (!all.length) return false;
            var i = all.indexOf(document.activeElement);
            var next = \(backward ? "i <= 0 ? all[all.length - 1] : all[i - 1]" : "i < 0 || i >= all.length - 1 ? all[0] : all[i + 1]");
            next.focus();
            return true;
        })();
        """
    }

    /// Dispatches a synthetic keyboard event at the focused element. Returns
    /// true if a listener cancelled it.
    private static func dispatchDOMKey(in webview: WKWebView, type: String, key: String, keyCode: Int, modifiers: NSEvent.ModifierFlags) async -> Bool {
        let lit = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let js = """
        (function() {
            var el = document.activeElement || document.body;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            var k = \(lit);
            var code = k.length === 1 ? (/[a-z]/i.test(k) ? 'Key' + k.toUpperCase() : (/[0-9]/.test(k) ? 'Digit' + k : '')) : k;
            var ev = new KeyboardEvent('\(type)', {
                key: k, code: code, keyCode: \(keyCode), which: \(keyCode),
                bubbles: true, cancelable: true, composed: true,
                shiftKey: \(modifiers.contains(.shift)), ctrlKey: \(modifiers.contains(.control)),
                altKey: \(modifiers.contains(.option)), metaKey: \(modifiers.contains(.command))
            });
            return !(el || document).dispatchEvent(ev);
        })();
        """
        return await evalJS(in: webview, js) as? Bool ?? false
    }

    @discardableResult
    private static func evalJS(in webview: WKWebView, _ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            webview.evaluateJavaScript(js) { value, _ in cont.resume(returning: value) }
        }
    }

    /// Mac virtual keyCode → DOM legacy `keyCode` for the named keys.
    private static func legacyKeyCode(forMacKeyCode code: UInt16) -> UInt16 {
        switch code {
        case 36: return 13   // enter
        case 48: return 9    // tab
        case 53: return 27   // escape
        case 51: return 8    // backspace
        case 117: return 46  // delete
        case 49: return 32   // space
        case 123: return 37; case 126: return 38; case 124: return 39; case 125: return 40
        case 115: return 36; case 119: return 35; case 116: return 33; case 121: return 34
        default: return 0
        }
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
