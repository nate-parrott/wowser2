import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif

// Clicks and form submissions on web pages.
//
// Clicks: `WebContentWebView.mouseDown` calls `noteMouseDown` before the web
// process sees the event. We convert the point to CSS pixels and hit-test the
// DOM with `elementFromPoint`, walking up to the nearest interactive ancestor
// (link, button, input, role=…), and record its accessible name, text, href
// and attributes. Any typed text still buffered is flushed first so the log
// reads in order: typed → click.
//
// Forms: a user script (page world, so `HTMLFormElement.prototype.submit`
// can be patched — programmatic submits fire no event) posts the form's
// fields to `MemoryFormBridge` right before submission. Password / card /
// CVV / SSN / OTP / file / hidden fields are never included; values that look
// like a card number are redacted; everything is size-capped in JS again in
// Swift.

extension MemoryStore {

    // MARK: - Clicks

    #if os(macOS)
    /// From `WebContentWebKit`, before the event reaches WebKit.
    func noteMouseDown(webContent: WebContent, webview: WKWebView, event: NSEvent) {
        guard isActive, isEnabled(webContent.datastoreUUID) else { return }
        guard let url = webview.url, Self.pageType(for: url) != "other", NativePageKey(url: url) == nil else { return }
        flushTypedBuffer()
        var p = webview.convert(event.locationInWindow, from: nil)
        if !webview.isFlipped { p.y = webview.bounds.height - p.y }
        let zoom = max(0.1, webview.pageZoom)
        let x = p.x / zoom, y = p.y / zoom
        let scope = webContent.datastoreUUID
        let paneID = webContent.id
        let state = BrowserStore.shared.model
        let tabID = state.paneToTabMapping[paneID]
        let space = Self.space(forPane: paneID, in: state)
        let title = webContent.info.title
        let js = Self.clickHitTestJS.replacingOccurrences(of: "__X__", with: String(format: "%.1f", x))
            .replacingOccurrences(of: "__Y__", with: String(format: "%.1f", y))
        webview.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any], let summary = dict["summary"] as? String, !summary.isEmpty else { return }
            var extra = dict
            extra["x"] = Int(x); extra["y"] = Int(y)
            extra["summary"] = nil
            var event = MemoryEvent(kind: "click", pageType: Self.pageType(for: url), paneID: paneID.raw, tabID: tabID?.raw,
                                    url: url, title: title, text: summary, extra: extra)
            event.spaceID = space?.id; event.spaceName = space?.name
            self.record(scope: scope, event)
        }
    }

    /// Hit-tests the DOM at CSS point (__X__, __Y__) and describes the nearest
    /// interactive element. Returns null for clicks on nothing in particular
    /// (bare body/html) so scrolling-type clicks aren't logged.
    static let clickHitTestJS = """
    (() => {
        const clip = (s, n) => { s = (s || '').replace(/\\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };
        let el = document.elementFromPoint(__X__, __Y__);
        for (let i = 0; i < 4 && el && el.tagName === 'IFRAME'; i++) {
            try {
                const r = el.getBoundingClientRect();
                const d = el.contentDocument;
                el = d ? d.elementFromPoint(__X__ - r.left, __Y__ - r.top) : null;
            } catch (_) { el = null; }
        }
        if (!el || el === document.body || el === document.documentElement) return null;
        const interactive = e => {
            if (!e || e === document.body) return false;
            const t = e.tagName;
            if (['A','BUTTON','INPUT','SELECT','TEXTAREA','SUMMARY','LABEL','OPTION'].includes(t)) return true;
            const role = e.getAttribute && e.getAttribute('role');
            if (role && /^(button|link|tab|menuitem|menuitemcheckbox|menuitemradio|option|checkbox|radio|switch|treeitem|row|listitem|gridcell|cell|combobox|textbox|searchbox|slider|spinbutton)$/.test(role)) return true;
            if (e.hasAttribute && (e.hasAttribute('onclick') || e.getAttribute('tabindex') === '0' || e.getAttribute('contenteditable') === 'true')) return true;
            return false;
        };
        let target = el;
        for (let i = 0; i < 8 && target && !interactive(target); i++) target = target.parentElement;
        if (!target || target === document.body) target = el;
        const tag = target.tagName.toLowerCase();
        const role = target.getAttribute('role') || '';
        const type = tag === 'input' ? (target.getAttribute('type') || 'text').toLowerCase() : '';
        const sensitive = type === 'password' || /cc-|one-time-code|password|passwd|cvv|cvc|card-?number|ssn/i.test((target.name || '') + ' ' + (target.id || '') + ' ' + (target.getAttribute('autocomplete') || ''));
        let ariaLabel = target.getAttribute('aria-label') || '';
        if (!ariaLabel && target.getAttribute('aria-labelledby')) {
            ariaLabel = target.getAttribute('aria-labelledby').split(/\\s+/).map(id => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ');
        }
        let labelText = '';
        if (target.labels && target.labels.length) labelText = target.labels[0].textContent;
        let text = clip(target.innerText || target.textContent || target.getAttribute('alt') || target.getAttribute('title') || '', 300);
        if (['input','select','textarea'].includes(tag) && !sensitive) {
            const v = ['checkbox','radio'].includes(type) ? (target.checked ? 'checked' : 'unchecked') : (target.value || '');
            if (v && ['submit','button','reset','checkbox','radio'].includes(type)) text = clip(v, 120);
        }
        const link = target.closest('a[href]');
        const href = link ? clip(link.href, 500) : '';
        const name = clip(ariaLabel || labelText || text || target.getAttribute('placeholder') || target.getAttribute('title') || target.getAttribute('name') || target.id || '', 200);
        let what = role || (tag === 'a' ? 'link' : tag === 'input' ? (type + ' input') : tag);
        let summary = what + (name ? ' "' + name + '"' : '');
        if (href) summary += ' → ' + href;
        else if (!name) summary += (target.className && typeof target.className === 'string') ? ' .' + clip(target.className, 60).split(' ').join('.') : '';
        return {
            summary, tag, role, ariaLabel: clip(ariaLabel, 200), text, href,
            name: clip(target.getAttribute('name') || '', 100), id: clip(target.id || '', 100), inputType: type,
            hitTag: el.tagName.toLowerCase()
        };
    })()
    """
    #endif

    // MARK: - Forms

    /// From `MemoryFormBridge`: a page is about to submit a form.
    func noteFormSubmit(webContent: WebContent, url: URL?, body: [String: Any]) {
        guard isActive, isEnabled(webContent.datastoreUUID) else { return }
        guard let fields = body["fields"] as? [[String: Any]], !fields.isEmpty else { return }
        flushTypedBuffer()
        let pageURL = url ?? webContent.info.url
        var cleanFields: [[String: String]] = []
        var lines: [String] = []
        var total = 0
        for f in fields.prefix(Self.maxFormFields) {
            let name = Self.clipped(f["name"] as? String, 100) ?? ""
            let label = Self.clipped(f["label"] as? String, 200) ?? ""
            let type = Self.clipped(f["type"] as? String, 40) ?? ""
            guard var value = f["value"] as? String else { continue }
            if Self.isSensitiveField(name: name, label: label, type: type) { continue }
            value = Self.redactCardNumbers(value)
            value = Self.clipped(value, Self.maxFormFieldChars) ?? ""
            guard !value.isEmpty else { continue }
            total += value.count
            if total > Self.maxFormTotalChars { break }
            cleanFields.append(["name": name, "label": label, "type": type, "value": value])
            lines.append("\(label.nilIfEmpty ?? name.nilIfEmpty ?? type): \(value)")
        }
        guard !lines.isEmpty else { return }
        let action = Self.clipped(body["action"] as? String, 500)
        let method = Self.clipped(body["method"] as? String, 10)
        let paneID = webContent.id
        let state = BrowserStore.shared.model
        let tabID = state.paneToTabMapping[paneID]
        var event = MemoryEvent(
            kind: "form", pageType: Self.pageType(for: pageURL), paneID: paneID.raw, tabID: tabID?.raw,
            url: pageURL, title: webContent.info.title, text: lines.joined(separator: "\n"),
            extra: ["action": action ?? NSNull(), "method": method ?? NSNull(), "fields": cleanFields,
                    "formId": Self.clipped(body["formId"] as? String, 100) ?? NSNull()])
        if let space = Self.space(forPane: paneID, in: state) { event.spaceID = space.id; event.spaceName = space.name }
        record(scope: webContent.datastoreUUID, event)
    }

    static let maxFormFields = 60
    static let maxFormFieldChars = 4_000
    static let maxFormTotalChars = 20_000

    static func isSensitiveField(name: String, label: String, type: String) -> Bool {
        if ["password", "hidden", "file", "submit", "button", "image", "reset"].contains(type.lowercased()) { return true }
        let hint = (name + " " + label).lowercased()
        return hint.range(of: #"cc-|one-time-code|password|passwd|cvv|cvc|card-?number|card num|security code|\bssn\b|social security|otp\b|verification code"#, options: .regularExpression) != nil
    }

    /// Replace 13–19 digit runs (allowing spaces/dashes between groups) with a
    /// placeholder. Coarse on purpose: false positives cost a phone-number-ish
    /// string, false negatives cost a card number.
    static func redactCardNumbers(_ s: String) -> String {
        s.replacingOccurrences(of: #"\b\d(?:[ -]?\d){12,18}\b"#, with: "[number redacted]", options: .regularExpression)
    }

    /// Injected into every web page (page world) at document start.
    static let formCaptureUserScript = """
    (function() {
        if (location.protocol !== 'http:' && location.protocol !== 'https:') return;
        if (window.__tangFormCapture) return;
        window.__tangFormCapture = true;
        const clip = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) : s; };
        const SKIP = ['password','hidden','file','submit','button','image','reset'];
        const SENS = /cc-|one-time-code|password|passwd|cvv|cvc|card-?number|ssn/i;
        function labelFor(el) {
            if (el.labels && el.labels.length) return el.labels[0].textContent;
            return el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '';
        }
        function collect(form) {
            const out = [];
            let total = 0;
            for (const el of Array.from(form.elements || [])) {
                if (out.length >= 60) break;
                const tag = (el.tagName || '').toLowerCase();
                if (!['input','select','textarea'].includes(tag)) continue;
                const type = tag === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : tag;
                if (SKIP.includes(type)) continue;
                const name = clip(el.name || el.id || '', 100);
                const label = clip((labelFor(el) || '').replace(/\\s+/g, ' ').trim(), 200);
                if (SENS.test(name + ' ' + (el.getAttribute('autocomplete') || '') + ' ' + label)) continue;
                let value = '';
                if (type === 'checkbox' || type === 'radio') { if (!el.checked) continue; value = el.value === 'on' ? 'checked' : clip(el.value, 200); }
                else if (tag === 'select') value = Array.from(el.selectedOptions || []).map(o => o.textContent.trim()).join(', ');
                else value = el.value || '';
                value = clip(value, 4000);
                if (!value) continue;
                total += value.length;
                if (total > 20000) break;
                out.push({ name, label, type, value });
            }
            return out;
        }
        function report(form) {
            try {
                if (!(form instanceof HTMLFormElement)) return;
                const fields = collect(form);
                if (!fields.length) return;
                const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tangMemoryForm;
                if (!h) return;
                h.postMessage({
                    action: clip(form.action || '', 500),
                    method: clip((form.method || 'get').toLowerCase(), 10),
                    formId: clip(form.id || form.name || '', 100),
                    url: clip(location.href, 1000),
                    fields
                });
            } catch (_) {}
        }
        window.addEventListener('submit', e => { if (e.target) report(e.target); }, true);
        try {
            const proto = HTMLFormElement.prototype;
            const orig = proto.submit;
            proto.submit = function() { report(this); return orig.apply(this, arguments); };
        } catch (_) {}
    })();
    """
}

/// Script message handler for `formCaptureUserScript`. One per webview,
/// holding it weakly so the handler (retained by the content controller)
/// doesn't keep the web content alive.
final class MemoryFormBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "tangMemoryForm"
    private weak var webContent: WebContent?

    init(webContent: WebContent) { self.webContent = webContent }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard MemoryStore.shared.isActive, let webContent, let body = message.body as? [String: Any] else { return }
        let proto = message.frameInfo.securityOrigin.`protocol`
        guard proto == "http" || proto == "https" else { return }
        // Only trust the page URL from the main frame; subframes get their frame's URL.
        let url = message.frameInfo.isMainFrame ? (message.webView?.url ?? message.frameInfo.request.url) : message.frameInfo.request.url
        MemoryStore.shared.noteFormSubmit(webContent: webContent, url: url, body: body)
    }

    /// Adds the user script (fresh configs only; inherited popup configs
    /// already carry it) and (re)points the message handler at `webContent`.
    static func install(on config: WKWebViewConfiguration, isFreshConfig: Bool, webContent: WebContent) {
        let ucc = config.userContentController
        if isFreshConfig {
            ucc.addUserScript(WKUserScript(source: MemoryStore.formCaptureUserScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        } else {
            ucc.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        }
        ucc.add(MemoryFormBridge(webContent: webContent), contentWorld: .page, name: handlerName)
    }
}
