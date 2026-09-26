import Foundation

/// The read-only JavaScript the autofill session evaluates in a page to learn
/// about the focused field (and its form), to hit-test `<select>` elements
/// under a click, and the tiny targeted writes used to fill (focus a field,
/// pick a `<select>` option). Nothing here installs handlers, observers, or
/// DOM overlays — every call is a one-shot `evaluateJavaScript` whose result
/// is parsed into `AutofillFieldDescriptor`s on the Swift side.
public enum AutofillFieldQuery {

    /// Result of `snapshot`: the focused field, its form, and the page's selects.
    public struct Snapshot: Equatable, Sendable {
        public var url: URL?
        public var active: AutofillFieldDescriptor?
        /// Options when the active element is a `<select>`.
        public var activeSelect: SelectInfo?
        /// The active field's form siblings (includes the active field).
        public var form: [AutofillFieldDescriptor]
        /// Every popup-style `<select>` in the top document, for click hit-testing.
        public var selects: [SelectRect]

        public init(url: URL? = nil, active: AutofillFieldDescriptor? = nil, activeSelect: SelectInfo? = nil, form: [AutofillFieldDescriptor] = [], selects: [SelectRect] = []) {
            self.url = url; self.active = active; self.activeSelect = activeSelect; self.form = form; self.selects = selects
        }
    }

    public struct SelectOption: Equatable, Sendable, Identifiable {
        public var index: Int
        public var label: String
        public var value: String
        public var group: String?
        public var disabled: Bool
        public var id: Int { index }

        public init(index: Int, label: String, value: String, group: String? = nil, disabled: Bool = false) {
            self.index = index; self.label = label; self.value = value; self.group = group; self.disabled = disabled
        }
    }

    public struct SelectInfo: Equatable, Sendable {
        public var field: AutofillFieldDescriptor
        public var options: [SelectOption]
        public var selectedIndex: Int

        public init(field: AutofillFieldDescriptor, options: [SelectOption], selectedIndex: Int) {
            self.field = field; self.options = options; self.selectedIndex = selectedIndex
        }
    }

    public struct SelectRect: Equatable, Sendable {
        public var fieldIndex: Int
        public var rect: AutofillRect

        public init(fieldIndex: Int, rect: AutofillRect) { self.fieldIndex = fieldIndex; self.rect = rect }
    }

    /// A handle to a field for follow-up calls (focus / fill / verify).
    public struct FieldRef: Equatable, Sendable {
        public var fieldIndex: Int
        public var framePath: [Int]

        public init(fieldIndex: Int, framePath: [Int] = []) { self.fieldIndex = fieldIndex; self.framePath = framePath }
        public init(_ d: AutofillFieldDescriptor) { self.init(fieldIndex: d.fieldIndex, framePath: d.framePath ?? []) }

        var jsArgs: String { "{fieldIndex: \(fieldIndex), framePath: \(framePath)}" }
    }

    // MARK: - Calls

    /// Describes `document.activeElement` (descending into same-origin
    /// iframes), its form, and all top-level selects.
    public static var snapshotActiveJS: String { call("{mode: 'active'}") }

    /// Describes a specific field (and its form) — used to re-read values
    /// right before a submit without depending on focus.
    public static func snapshotFieldJS(_ ref: FieldRef) -> String { call("{mode: 'field', ref: \(ref.jsArgs)}") }

    /// Describes the `<select>` under a viewport point, or `active: null`.
    public static func selectAtPointJS(x: Double, y: Double) -> String { call("{mode: 'point', x: \(jsNum(x)), y: \(jsNum(y))}") }

    /// Only the select rects (cheap; used after scrolls).
    public static var selectRectsJS: String { call("{mode: 'selects'}") }

    /// Focus a field (so a native text insert lands in it). Returns true on success.
    public static func focusFieldJS(_ ref: FieldRef, selectAll: Bool) -> String { call("{mode: 'focus', ref: \(ref.jsArgs), selectAll: \(selectAll)}") }

    /// Pick a `<select>` option by index, firing input/change like a user would.
    public static func setSelectIndexJS(_ ref: FieldRef, index: Int) -> String { call("{mode: 'setSelect', ref: \(ref.jsArgs), index: \(index)}") }

    /// The current value of a field (after a fill, to verify it took).
    public static func readValueJS(_ ref: FieldRef) -> String { call("{mode: 'value', ref: \(ref.jsArgs)}") }

    private static func call(_ args: String) -> String {
        "(" + library + ")(" + args + ")"
    }

    private static func jsNum(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        return String(format: "%.2f", v)
    }

    // MARK: - Parsing

    public static func parseSnapshot(_ any: Any?) -> Snapshot? {
        guard let dict = any as? [String: Any] else { return nil }
        var snap = Snapshot()
        snap.url = (dict["url"] as? String).flatMap { URL(string: $0) }
        snap.active = (dict["active"] as? [String: Any]).flatMap(decodeDescriptor)
        if let sel = dict["activeSelect"] as? [String: Any], let field = snap.active {
            snap.activeSelect = parseSelectInfo(sel, field: field)
        }
        snap.form = ((dict["form"] as? [[String: Any]]) ?? []).compactMap(decodeDescriptor)
        snap.selects = ((dict["selects"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let i = intValue(s["fieldIndex"]), let r = s["rect"] as? [String: Any], let rect = parseRect(r) else { return nil }
            return SelectRect(fieldIndex: i, rect: rect)
        }
        return snap
    }

    public static func parseSelectInfo(_ sel: [String: Any], field: AutofillFieldDescriptor) -> SelectInfo? {
        let options = ((sel["options"] as? [[String: Any]]) ?? []).enumerated().map { i, o in
            SelectOption(
                index: intValue(o["index"]) ?? i,
                label: (o["label"] as? String) ?? "",
                value: (o["value"] as? String) ?? "",
                group: o["group"] as? String,
                disabled: (o["disabled"] as? Bool) ?? false
            )
        }
        return SelectInfo(field: field, options: options, selectedIndex: intValue(sel["selectedIndex"]) ?? -1)
    }

    static func decodeDescriptor(_ dict: [String: Any]) -> AutofillFieldDescriptor? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let d = try? JSONDecoder().decode(AutofillFieldDescriptor.self, from: data)
        else { return nil }
        return d
    }

    static func parseRect(_ r: [String: Any]) -> AutofillRect? {
        guard let x = doubleValue(r["x"]), let y = doubleValue(r["y"]), let w = doubleValue(r["width"]), let h = doubleValue(r["height"]) else { return nil }
        return AutofillRect(x: x, y: y, width: w, height: h)
    }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - JS library

    /// One function, `(args) => result`. Kept dependency-free and side-effect
    /// free except for the explicit `focus` / `setSelect` modes.
    static let library: String = #"""
    function(args) {
        const TEXT_TYPES = ['', 'text', 'email', 'password', 'tel', 'search', 'url', 'number'];
        const SKIP_TYPES = ['hidden', 'submit', 'button', 'checkbox', 'radio', 'file', 'image', 'reset', 'range', 'color'];

        function norm(s) { return (s || '').replace(/\s+/g, ' ').trim(); }

        // Resolve the document for a frame path (top doc = []).
        function docForPath(path) {
            let doc = document;
            for (const i of (path || [])) {
                try {
                    const frames = doc.querySelectorAll('iframe');
                    const f = frames[i];
                    if (!f || !f.contentDocument) return null;
                    doc = f.contentDocument;
                } catch (_) { return null; }
            }
            return doc;
        }
        function controlsIn(doc) { return Array.from(doc.querySelectorAll('input, textarea, select')); }
        function frameOffset(path) {
            // Sum iframe rects so nested rects come back in top-viewport coords.
            let doc = document, dx = 0, dy = 0;
            for (const i of (path || [])) {
                const f = doc.querySelectorAll('iframe')[i];
                if (!f) break;
                const r = f.getBoundingClientRect();
                dx += r.left; dy += r.top;
                doc = f.contentDocument;
                if (!doc) break;
            }
            return { dx, dy };
        }

        function labelText(el, doc) {
            const parts = [];
            try { if (el.labels) for (const l of el.labels) { const t = norm(l.innerText || l.textContent); if (t) parts.push(t); } } catch (_) {}
            const lb = el.getAttribute('aria-labelledby');
            if (lb) for (const id of lb.split(/\s+/)) { const n = doc.getElementById(id); if (n) { const t = norm(n.innerText || n.textContent); if (t) parts.push(t); } }
            const db = el.getAttribute('aria-describedby');
            if (!parts.length && db) for (const id of db.split(/\s+/)) { const n = doc.getElementById(id); if (n) { const t = norm(n.innerText || n.textContent); if (t) parts.push(t); } }
            return Array.from(new Set(parts)).join(' ').slice(0, 120);
        }
        function previousText(el) {
            let node = el;
            for (let depth = 0; depth < 6 && node; depth++) {
                let sib = node.previousSibling;
                while (sib) {
                    if (sib.nodeType === 3) { const t = norm(sib.nodeValue); if (t) return t.slice(0, 80); }
                    else if (sib.nodeType === 1) {
                        const tag = sib.tagName;
                        if (!['SCRIPT', 'STYLE', 'INPUT', 'SELECT', 'TEXTAREA', 'BUTTON', 'IFRAME'].includes(tag)) {
                            const t = norm(sib.innerText || sib.textContent);
                            if (t) return t.slice(-80);
                        }
                    }
                    sib = sib.previousSibling;
                }
                node = node.parentElement;
                if (!node || ['FORM', 'BODY', 'HTML'].includes(node.tagName)) break;
            }
            return '';
        }
        function fieldType(el) {
            const tag = el.tagName.toLowerCase();
            if (tag === 'input') return (el.getAttribute('type') || 'text').toLowerCase();
            return tag;
        }
        function isSkippable(el) {
            return el.tagName === 'INPUT' && SKIP_TYPES.includes(fieldType(el));
        }
        function describe(el, doc, path, all, formInfo) {
            const tag = el.tagName.toLowerCase();
            const type = fieldType(el);
            const off = frameOffset(path);
            const r = el.getBoundingClientRect();
            const d = {
                fieldIndex: all.indexOf(el),
                tag, type,
                name: el.getAttribute('name') || '',
                id: el.id || '',
                autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
                placeholder: norm(el.getAttribute('placeholder')),
                ariaLabel: norm(el.getAttribute('aria-label')),
                title: norm(el.getAttribute('title')),
                className: (typeof el.className === 'string' ? el.className : '').slice(0, 120),
                label: labelText(el, doc),
                previousText: previousText(el),
                maxLength: (el.maxLength > 0 ? el.maxLength : null),
                readOnly: !!el.readOnly,
                disabled: !!el.disabled,
                formIndex: el.form ? Array.from(doc.forms).indexOf(el.form) : null,
                formHasPassword: formInfo.hasPassword,
                passwordFieldCount: formInfo.passwordCount,
                indexInForm: formInfo.members.indexOf(el),
                textFieldCountInForm: formInfo.textCount,
                rect: { x: r.left + off.dx, y: r.top + off.dy, width: r.width, height: r.height },
                framePath: path || [],
            };
            if (tag === 'select') {
                d.optionCount = el.options.length;
                d.optionSample = Array.from(el.options).slice(0, 8).map(o => norm(o.label || o.text)).filter(Boolean);
                d.value = el.selectedIndex >= 0 ? norm(el.options[el.selectedIndex].label || el.options[el.selectedIndex].text) : '';
            } else if (tag === 'input' || tag === 'textarea') {
                d.value = (el.value == null ? '' : String(el.value)).slice(0, 512);
            }
            return d;
        }
        // Siblings: the owning form's controls, or (form-less) the nearest
        // controls around the field in document order.
        function formMembers(el, doc, all) {
            let members;
            if (el.form) {
                members = Array.from(el.form.elements).filter(e => e.tagName && ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName) && !isSkippable(e));
            } else {
                const idx = all.indexOf(el);
                members = all.slice(Math.max(0, idx - 12), idx + 13).filter(e => !e.form && !isSkippable(e));
            }
            const pw = members.filter(e => e.tagName === 'INPUT' && fieldType(e) === 'password');
            const text = members.filter(e => e.tagName === 'INPUT' && TEXT_TYPES.includes(fieldType(e)));
            return { members, hasPassword: pw.length > 0, passwordCount: pw.length, textCount: text.length };
        }
        function selectInfo(el) {
            const opts = [];
            Array.from(el.options).forEach((o, i) => {
                const g = o.parentElement && o.parentElement.tagName === 'OPTGROUP' ? norm(o.parentElement.label) : null;
                opts.push({ index: i, label: norm(o.label || o.text), value: String(o.value), group: g, disabled: !!o.disabled });
            });
            return { options: opts, selectedIndex: el.selectedIndex };
        }
        function isPopupSelect(el) {
            return el.tagName === 'SELECT' && !el.multiple && (el.size || 0) <= 1 && !el.disabled;
        }
        function selectRects() {
            const all = controlsIn(document);
            const out = [];
            all.forEach((el, i) => {
                if (!isPopupSelect(el)) return;
                const r = el.getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) return;
                if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return;
                out.push({ fieldIndex: i, rect: { x: r.left, y: r.top, width: r.width, height: r.height } });
            });
            return out;
        }
        function activeElement() {
            let el = document.activeElement, doc = document, path = [];
            for (let i = 0; i < 4 && el && el.tagName === 'IFRAME'; i++) {
                try {
                    const frames = Array.from(doc.querySelectorAll('iframe'));
                    const idx = frames.indexOf(el);
                    const inner = el.contentDocument;
                    if (idx < 0 || !inner) return null;
                    path.push(idx); doc = inner; el = inner.activeElement;
                } catch (_) { return null; }
            }
            // Shadow DOM: descend to the innermost focused element.
            for (let i = 0; i < 6 && el && el.shadowRoot && el.shadowRoot.activeElement; i++) el = el.shadowRoot.activeElement;
            if (!el || el === doc.body || el === doc.documentElement) return null;
            return { el, doc, path };
        }
        function resolveRef(ref) {
            const doc = docForPath(ref && ref.framePath);
            if (!doc) return null;
            const all = controlsIn(doc);
            const el = all[ref.fieldIndex];
            if (!el) return null;
            return { el, doc, path: ref.framePath || [], all };
        }
        function fullSnapshot(target) {
            const out = { url: location.href, active: null, activeSelect: null, form: [], selects: selectRects() };
            if (!target) return out;
            const { el, doc, path } = target;
            const all = target.all || controlsIn(doc);
            const tag = el.tagName;
            if (!['INPUT', 'TEXTAREA', 'SELECT'].includes(tag)) {
                if (el.isContentEditable) {
                    const r = el.getBoundingClientRect();
                    const off = frameOffset(path);
                    out.active = { fieldIndex: -1, tag: 'contenteditable', type: 'contenteditable', rect: { x: r.left + off.dx, y: r.top + off.dy, width: r.width, height: r.height }, framePath: path };
                }
                return out;
            }
            if (isSkippable(el)) return out;
            const fi = formMembers(el, doc, all);
            out.active = describe(el, doc, path, all, fi);
            if (tag === 'SELECT') out.activeSelect = selectInfo(el);
            out.form = fi.members.map(m => describe(m, doc, path, all, fi));
            return out;
        }

        switch (args.mode) {
        case 'active':
            return fullSnapshot(activeElement());
        case 'field': {
            const t = resolveRef(args.ref);
            return fullSnapshot(t);
        }
        case 'point': {
            let el = document.elementFromPoint(args.x, args.y);
            for (let i = 0; i < 6 && el && el.shadowRoot; i++) {
                const inner = el.shadowRoot.elementFromPoint(args.x, args.y);
                if (!inner || inner === el) break;
                el = inner;
            }
            while (el && el.tagName !== 'SELECT') el = el.parentElement;
            if (!el || !isPopupSelect(el)) return { url: location.href, active: null, activeSelect: null, form: [], selects: [] };
            const all = controlsIn(document);
            const fi = formMembers(el, document, all);
            return { url: location.href, active: describe(el, document, [], all, fi), activeSelect: selectInfo(el), form: [], selects: [] };
        }
        case 'selects':
            return { url: location.href, active: null, activeSelect: null, form: [], selects: selectRects() };
        case 'focus': {
            const t = resolveRef(args.ref);
            if (!t) return false;
            if (t.el.disabled || t.el.readOnly) return false;
            try { t.el.focus({ preventScroll: false }); } catch (_) { t.el.focus(); }
            if (args.selectAll && typeof t.el.select === 'function') { try { t.el.select(); } catch (_) {} }
            const active = activeElement();
            return !!active && active.el === t.el;
        }
        case 'setSelect': {
            const t = resolveRef(args.ref);
            if (!t || t.el.tagName !== 'SELECT') return false;
            const i = args.index;
            if (i < 0 || i >= t.el.options.length || t.el.options[i].disabled) return false;
            if (t.el.selectedIndex !== i) {
                t.el.selectedIndex = i;
                t.el.dispatchEvent(new Event('input', { bubbles: true }));
                t.el.dispatchEvent(new Event('change', { bubbles: true }));
            }
            return t.el.selectedIndex === i;
        }
        case 'value': {
            const t = resolveRef(args.ref);
            if (!t) return null;
            return t.el.value == null ? '' : String(t.el.value);
        }
        default:
            return null;
        }
    }
    """#
}
