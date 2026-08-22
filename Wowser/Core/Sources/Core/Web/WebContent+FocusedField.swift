import Foundation
import WebKit

// Heuristic info about the text field currently focused in a page (used by dictation)
public struct FocusedTextField: Equatable, Codable {
    public var frame: CGRect // In the webview's coordinate space
}

// Detects whether a text field (input, textarea, contenteditable) is focused in the page.
// This is polled — not observed — so callers should trigger refreshes on user interaction
// (clicks, key events) and navigation/metadata changes. Refreshes are debounced to ~200ms.
extension WebContent {
    private static let debounceWorkItemKey = AssociatedObjectKey<DispatchWorkItem>()
    private static let focusedFieldJS = """
    (function() {
        function isEditable(el) {
            if (!el) { return false; }
            if (el.isContentEditable) { return true; }
            var tag = (el.tagName || '').toLowerCase();
            if (tag === 'textarea') { return true; }
            if (tag === 'input') {
                var t = (el.type || 'text').toLowerCase();
                return ['text', 'search', 'email', 'url', 'tel', 'number', 'password'].indexOf(t) >= 0;
            }
            return false;
        }
        var el = document.activeElement;
        var offsetX = 0, offsetY = 0;
        // Descend into same-origin iframes
        while (el && el.tagName && el.tagName.toLowerCase() === 'iframe') {
            try {
                var fr = el.getBoundingClientRect();
                var inner = el.contentDocument.activeElement;
                if (!inner) { break; }
                offsetX += fr.left;
                offsetY += fr.top;
                el = inner;
            } catch (e) { el = null; }
        }
        if (!isEditable(el)) {
            return { focused: false, x: 0, y: 0, w: 0, h: 0 };
        }
        var r = el.getBoundingClientRect();
        return { focused: true, x: r.left + offsetX, y: r.top + offsetY, w: r.width, h: r.height };
    })()
    """

    private struct FocusedFieldJSResult: Codable {
        var focused: Bool
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    public func refreshFocusedTextFieldDebounced() {
        assertOnMainThread()
        if getAssociatedObject(forKey: Self.debounceWorkItemKey) != nil {
            return // refresh already scheduled
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setAssociatedObject(nil, forKey: Self.debounceWorkItemKey)
            self.refreshFocusedTextFieldNow()
        }
        setAssociatedObject(item, forKey: Self.debounceWorkItemKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func refreshFocusedTextFieldNow() {
        guard info.url != nil else {
            setFocusedTextField(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.webview.evaluateJS(Self.focusedFieldJS, resultType: FocusedFieldJSResult.self)
                if result.focused {
                    self.setFocusedTextField(FocusedTextField(frame: CGRect(x: result.x, y: result.y, width: result.w, height: result.h)))
                } else {
                    self.setFocusedTextField(nil)
                }
            } catch {
                self.setFocusedTextField(nil)
            }
        }
    }

    // MARK: - Text insertion (used by dictation to commit text into the focused field)

    // Inserts text at the cursor in the focused field via a synthetic editing command
    public func insertTextIntoFocusedField(_ text: String) {
        let js = """
        (function() {
            var doc = document;
            var el = document.activeElement;
            while (el && el.tagName && el.tagName.toLowerCase() === 'iframe') {
                try { doc = el.contentDocument; el = doc.activeElement; } catch (e) { break; }
            }
            try {
                doc.execCommand('insertText', false, \(text.encodedAsJSONString));
                return true;
            } catch (e) { return false; }
        })()
        """
        webview.evaluateJavaScript(js, completionHandler: nil)
    }

    // Reads the current contents of the focused field plus lightweight page context (for AI cleanup)
    public struct FocusedFieldContext: Codable {
        public var fieldValue: String
        public var pageText: String
    }

    public func readFocusedFieldContext() async throws -> FocusedFieldContext {
        let js = """
        (function() {
            var doc = document;
            var el = document.activeElement;
            while (el && el.tagName && el.tagName.toLowerCase() === 'iframe') {
                try { doc = el.contentDocument; el = doc.activeElement; } catch (e) { break; }
            }
            var value = '';
            if (el) {
                if (typeof el.value === 'string') { value = el.value; }
                else if (el.isContentEditable) { value = el.innerText || ''; }
            }
            var pageText = '';
            try { pageText = (doc.body && doc.body.innerText) ? doc.body.innerText.slice(0, 2000) : ''; } catch (e) {}
            return { fieldValue: value.slice(0, 4000), pageText: pageText };
        })()
        """
        return try await webview.evaluateJS(js, resultType: FocusedFieldContext.self)
    }
}
