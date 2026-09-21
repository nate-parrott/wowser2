#if os(macOS)
import AppKit
import WebKit
import Combine

/// Per-webview autofill runtime. Owns the suggestion menu under the focused
/// field, the searchable `<select>` menu, key/mouse interception, native text
/// insertion, and form-submission capture.
///
/// Nothing is injected into pages: the webview subclass hands us NSEvents
/// before WebKit sees them (`handleKeyDown` / `handleMouseDown`), page state
/// is read with one-shot JS *queries* (`AutofillFieldQuery`), and text is
/// inserted through WebKit's own `NSTextInputClient` path — the same route a
/// keyboard or IME takes — so pages see ordinary `beforeinput`/`input` events.
@MainActor
public final class AutofillSession: ObservableObject {

    // MARK: - Published UI state

    public struct SuggestionMenu: Equatable {
        public var field: AutofillFieldDescriptor
        public var suggestions: [AutofillSuggestion]
        public var highlighted: Int
    }

    public struct SelectMenu: Equatable {
        public var info: AutofillFieldQuery.SelectInfo
        public var anchor: AutofillRect
        public var filter: String = ""
        public var highlighted: Int = 0

        public var filteredOptions: [AutofillFieldQuery.SelectOption] {
            let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
            let usable = info.options.filter { !$0.disabled || q.isEmpty }
            if q.isEmpty { return usable }
            let starts = usable.filter { $0.label.lowercased().hasPrefix(q) }
            let words = usable.filter { o in !starts.contains(where: { $0.index == o.index }) && o.label.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(q) }) }
            let contains = usable.filter { o in !starts.contains(where: { $0.index == o.index }) && !words.contains(where: { $0.index == o.index }) && (o.label.lowercased().contains(q) || o.value.lowercased().contains(q)) }
            return starts + words + contains
        }
    }

    @Published public private(set) var menu: SuggestionMenu?
    @Published public private(set) var selectMenu: SelectMenu?

    // MARK: - Wiring

    private weak var webview: WebContentWebView?
    private let webContentID: ID<WebContent>
    private let datastoreUUID: UUID

    public init(webview: WebContentWebView, webContentID: ID<WebContent>, datastoreUUID: UUID) {
        self.webview = webview
        self.webContentID = webContentID
        self.datastoreUUID = datastoreUUID
    }

    private var profileID: ID<Profile>? { AutofillStore.shared.profileID(forDatastoreUUID: datastoreUUID) }
    private var windowID: ID<WindowState>? { BrowserStore.shared.model.windowContaining(webContentId: webContentID)?.id }

    /// Asks the owner to re-run the focused-field query soon (debounced there).
    var requestRefresh: (() -> Void)?

    // MARK: - Page state

    private var lastSnapshot: AutofillFieldQuery.Snapshot?
    private var classifiedForm: [AutofillClassifiedField] = []
    private var activeClassified: AutofillClassifiedField?
    private var dismissedFieldSignature: String?
    private var selectRects: [AutofillFieldQuery.SelectRect] = []
    private var pageURL: URL?

    // MARK: - Snapshot intake

    /// Called after every focused-field query (clicks, keys, scrolls,
    /// navigation — coalesced by the owner).
    public func apply(snapshot: AutofillFieldQuery.Snapshot) {
        lastSnapshot = snapshot
        selectRects = snapshot.selects
        pageURL = snapshot.url

        guard let active = snapshot.active, active.tag == "input" || active.tag == "select" else {
            activeClassified = nil
            classifiedForm = []
            if menu != nil { menu = nil }
            return
        }

        // Classify the form as a group (context rules need siblings).
        let formFields = snapshot.form.isEmpty ? [active] : snapshot.form
        classifiedForm = AutofillFieldClassifier.classify(fields: formFields)
        activeClassified = classifiedForm.first { $0.descriptor.fieldIndex == active.fieldIndex && ($0.descriptor.framePath ?? []) == (active.framePath ?? []) }
            ?? AutofillFieldClassifier.classify(active)
        // Keep the freshest value/rect for the active field.
        activeClassified?.descriptor = active

        updateFormCapture()
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard AutofillSettings.isEnabled,
              let active = activeClassified, active.descriptor.tag == "input",
              AutofillHostMatcher.isFillableURL(pageURL), let host = pageURL?.host,
              let profileID
        else {
            if menu != nil { menu = nil }
            return
        }
        if dismissedFieldSignature == active.descriptor.signature {
            if menu != nil { menu = nil }
            return
        }
        let ctx = AutofillSuggestionContext(field: active, formFields: classifiedForm, pageHost: host, currentValue: active.descriptor.value ?? "")
        let suggestions = AutofillStore.shared.data(for: profileID).suggestions(for: ctx)
        guard !suggestions.isEmpty else {
            if menu != nil { menu = nil }
            return
        }
        var highlighted = 0
        if let menu, menu.field.signature == active.descriptor.signature,
           let previous = menu.suggestions[safe: menu.highlighted],
           let idx = suggestions.firstIndex(where: { $0.id == previous.id }) {
            highlighted = idx
        }
        let next = SuggestionMenu(field: active.descriptor, suggestions: suggestions, highlighted: highlighted)
        if menu != next { menu = next }
    }

    // MARK: - Keyboard

    /// Return true to swallow the event (WebKit never sees it).
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        if selectMenu != nil { return handleSelectMenuKey(event) }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }

        // Keyboard-open of a focused <select> (Space / Return / Option+Down).
        if AutofillSettings.searchableSelects, let snap = lastSnapshot, let sel = snap.activeSelect, let active = snap.active, active.isSelect,
           event.keyCode == 49 || event.keyCode == 36 || (event.keyCode == 125 && flags.contains(.option)) {
            openSelectMenu(info: sel, anchor: active.rect ?? AutofillRect(x: 0, y: 0, width: 0, height: 0), refreshFirst: true)
            return true
        }

        guard let menu else { return false }
        switch event.keyCode {
        case 125: // down
            moveHighlight(by: 1)
            return true
        case 126: // up
            moveHighlight(by: -1)
            return true
        case 53: // esc
            dismissedFieldSignature = menu.field.signature
            self.menu = nil
            return true
        case 36, 76: // return / enter
            if let s = menu.suggestions[safe: menu.highlighted] {
                Task { await accept(s) }
            }
            return true
        case 48: // tab — let focus move; the next query rebuilds the menu
            self.menu = nil
            return false
        default:
            return false
        }
    }

    /// Called right before a key event is handed to WebKit (never swallowed).
    /// Return on a form field is the moment to grab values for remembering.
    public func willSendKeyToPage(_ event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76 else { return }
        guard let active = lastSnapshot?.active, active.tag == "input" else { return }
        captureFormNow(reason: "enter")
    }

    private func moveHighlight(by delta: Int) {
        guard var m = menu, !m.suggestions.isEmpty else { return }
        m.highlighted = (m.highlighted + delta + m.suggestions.count) % m.suggestions.count
        menu = m
    }

    public func highlight(_ index: Int) {
        guard var m = menu, m.suggestions.indices.contains(index), m.highlighted != index else { return }
        m.highlighted = index
        menu = m
    }

    // MARK: - Mouse / <select> intercept

    private struct PendingClick {
        var down: NSEvent
        var followUps: [NSEvent] = []
        var fieldIndex: Int
        var startedAt = Date()
    }
    private var pendingClick: PendingClick?

    /// Return true to swallow the mouseDown.
    public func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let webview else { return false }
        let point = webview.convert(event.locationInWindow, from: nil)
        let zoom = max(webview.pageZoom, 0.01)
        let css = CGPoint(x: point.x / zoom, y: point.y / zoom)

        if let open = selectMenu {
            // Clicking the same select again toggles it closed; clicking
            // anywhere else on the page closes it and the click goes through.
            selectMenu = nil
            let r = open.anchor
            if CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: -2, dy: -2).contains(css) { return true }
            return false
        }

        // Any click while a form was being filled might be its submit button.
        if formCapture != nil { captureFormNow(reason: "click", at: css) }

        guard AutofillSettings.searchableSelects, event.type == .leftMouseDown, event.clickCount == 1, pendingClick == nil,
              AutofillHostMatcher.isFillableURL(pageURL) else { return false }
        guard let hit = selectRects.first(where: { s in
            CGRect(x: s.rect.x, y: s.rect.y, width: s.rect.width, height: s.rect.height).insetBy(dx: -1, dy: -1).contains(css)
        }) else { return false }

        // Swallow now, verify against the live DOM, then either open our menu
        // or replay the click so the page gets exactly what the user did.
        pendingClick = PendingClick(down: event, fieldIndex: hit.fieldIndex)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(AutofillFieldQuery.selectAtPointJS(x: css.x, y: css.y))
            self.resolvePendingClick(with: AutofillFieldQuery.parseSnapshot(result))
        }
        // Safety valve: never hold a click hostage.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let p = self.pendingClick, Date().timeIntervalSince(p.startedAt) >= 0.39 else { return }
            self.replayPendingClick()
        }
        return true
    }

    /// mouseUp / mouseDragged that arrive while a click is being verified.
    public func handleFollowUpMouse(_ event: NSEvent) -> Bool {
        guard pendingClick != nil else { return false }
        pendingClick?.followUps.append(event)
        return true
    }

    private func resolvePendingClick(with snapshot: AutofillFieldQuery.Snapshot?) {
        guard pendingClick != nil else { return }
        if let snap = snapshot, let active = snap.active, active.isSelect, let sel = snap.activeSelect, let rect = active.rect {
            pendingClick = nil
            // Give the select DOM focus (keyboard users expect it) without
            // opening WebKit's popup.
            Task { _ = await eval(AutofillFieldQuery.focusFieldJS(AutofillFieldQuery.FieldRef(active), selectAll: false)) }
            openSelectMenu(info: sel, anchor: rect, refreshFirst: false)
        } else {
            replayPendingClick()
        }
    }

    private func replayPendingClick() {
        guard let pending = pendingClick, let webview else { pendingClick = nil; return }
        pendingClick = nil
        webview.replay(pending.down)
        for e in pending.followUps { webview.replay(e) }
    }

    // MARK: - Select menu

    private func openSelectMenu(info: AutofillFieldQuery.SelectInfo, anchor: AutofillRect, refreshFirst: Bool) {
        menu = nil
        var initial = SelectMenu(info: info, anchor: anchor)
        initial.highlighted = max(0, info.options.firstIndex(where: { $0.index == info.selectedIndex }) ?? 0)
        selectMenu = initial
        guard refreshFirst else { return }
        // Options may have changed since the last snapshot; re-read them.
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(AutofillFieldQuery.snapshotFieldJS(AutofillFieldQuery.FieldRef(info.field)))
            guard var open = self.selectMenu, open.info.field.fieldIndex == info.field.fieldIndex,
                  let snap = AutofillFieldQuery.parseSnapshot(result), let fresh = snap.activeSelect, let rect = snap.active?.rect else { return }
            open.info = fresh
            open.anchor = rect
            open.highlighted = max(0, fresh.options.firstIndex(where: { $0.index == fresh.selectedIndex }) ?? 0)
            self.selectMenu = open
        }
    }

    private func handleSelectMenuKey(_ event: NSEvent) -> Bool {
        guard var open = selectMenu else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        let options = open.filteredOptions
        switch event.keyCode {
        case 53: // esc
            selectMenu = nil
            return true
        case 48: // tab: close and let focus move on
            selectMenu = nil
            return false
        case 125: // down
            if !options.isEmpty { open.highlighted = (open.highlighted + 1) % options.count }
        case 126: // up
            if !options.isEmpty { open.highlighted = (open.highlighted - 1 + options.count) % options.count }
        case 115: open.highlighted = 0                         // home
        case 119: open.highlighted = max(0, options.count - 1) // end
        case 116: open.highlighted = max(0, open.highlighted - 8) // page up
        case 121: open.highlighted = min(max(0, options.count - 1), open.highlighted + 8) // page down
        case 36, 76: // return / enter
            if let o = options[safe: open.highlighted] { chooseSelectOption(o) }
            return true
        case 51: // backspace
            if !open.filter.isEmpty { open.filter.removeLast(); open.highlighted = 0 }
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
                return true // swallow other function keys while the menu is up
            }
            open.filter += chars
            open.highlighted = 0
        }
        selectMenu = open
        return true
    }

    public func highlightSelectOption(_ index: Int) {
        guard var open = selectMenu, open.highlighted != index, open.filteredOptions.indices.contains(index) else { return }
        open.highlighted = index
        selectMenu = open
    }

    public func chooseSelectOption(_ option: AutofillFieldQuery.SelectOption) {
        guard let open = selectMenu else { return }
        selectMenu = nil
        let ref = AutofillFieldQuery.FieldRef(open.info.field)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.eval(AutofillFieldQuery.setSelectIndexJS(ref, index: option.index))
            self.restoreWebviewFocus()
            self.requestRefresh?()
        }
    }

    public func closeSelectMenu() {
        selectMenu = nil
        restoreWebviewFocus()
    }

    // MARK: - Filling

    /// Fills the chosen suggestion into the focused field (and, for logins,
    /// names and addresses, the sibling fields of the form), then moves on to
    /// the next field.
    public func accept(_ suggestion: AutofillSuggestion) async {
        guard let active = activeClassified, let profileID else { return }
        menu = nil
        dismissedFieldSignature = active.descriptor.signature

        var plan: [(AutofillFieldDescriptor, String)] = []
        func target(_ kinds: Set<AutofillFieldKind>) -> AutofillFieldDescriptor? {
            if let k = active.kind, kinds.contains(k) { return active.descriptor }
            return classifiedForm.first { $0.kind.map(kinds.contains) == true && !$0.descriptor.disabled && !$0.descriptor.readOnly }?.descriptor
        }

        switch suggestion.payload {
        case .value(let v):
            plan.append((active.descriptor, v))
        case .credential(let c):
            if let u = target([.username, .email, .phone]) { plan.append((u, c.username)) }
            if let p = target([.password]), let password = await AutofillStore.shared.password(for: c, profile: profileID) {
                plan.append((p, password))
            }
        case .name(let n):
            for f in classifiedForm {
                guard let k = f.kind, k.isName, let v = n.value(for: k) else { continue }
                plan.append((f.descriptor, v))
            }
            if plan.isEmpty, let k = active.kind, let v = n.value(for: k) { plan.append((active.descriptor, v)) }
        case .address(let a):
            for f in classifiedForm {
                guard let k = f.kind, k.isAddressPart, let v = a.value(for: k) else { continue }
                plan.append((f.descriptor, v))
            }
            if plan.isEmpty, let k = active.kind, let v = a.value(for: k) { plan.append((active.descriptor, v)) }
        }

        // The focused field first (so its value lands even if a later fill
        // trips a page script), then the rest in form order.
        plan.sort { l, r in
            let la = l.0.fieldIndex == active.descriptor.fieldIndex, ra = r.0.fieldIndex == active.descriptor.fieldIndex
            if la != ra { return la }
            return l.0.indexInForm < r.0.indexInForm
        }
        for (field, value) in plan {
            await fill(field: field, value: value)
        }

        AutofillStore.shared.markUsed(suggestion.payload, profile: profileID)

        // Back to where the user was, then on to the next field.
        _ = await eval(AutofillFieldQuery.focusFieldJS(AutofillFieldQuery.FieldRef(active.descriptor), selectAll: false))
        restoreWebviewFocus()
        if let webview {
            BrowserJSInputDispatcher.key(in: webview, key: "Tab", modifiers: [])
        }
        requestRefresh?()
    }

    /// Focus + select-all via a targeted DOM call, then insert the text through
    /// WebKit's text-input path. Falls back to synthesized keystrokes, and as a
    /// last resort to the element's value setter, verifying after each.
    private func fill(field: AutofillFieldDescriptor, value: String) async {
        guard let webview else { return }
        let ref = AutofillFieldQuery.FieldRef(field)
        if field.isSelect {
            // Pick the option whose label/value matches (case-insensitive,
            // then prefix — "CA" for "California").
            let result = await eval(AutofillFieldQuery.snapshotFieldJS(ref))
            guard let snap = AutofillFieldQuery.parseSnapshot(result), let info = snap.activeSelect else { return }
            let v = value.lowercased()
            let match = info.options.first { $0.label.lowercased() == v || $0.value.lowercased() == v }
                ?? info.options.first { $0.label.lowercased().hasPrefix(v) || v.hasPrefix($0.label.lowercased()) && !$0.label.isEmpty }
            if let match { _ = await eval(AutofillFieldQuery.setSelectIndexJS(ref, index: match.index)) }
            return
        }
        let focused = (await eval(AutofillFieldQuery.focusFieldJS(ref, selectAll: true)) as? Bool) ?? false
        guard focused else { return }
        webview.window?.makeFirstResponderIfNeeded(webview)

        webview.wowser_insertText(value)
        if await readValue(ref) == value { return }

        BrowserJSInputDispatcher.key(in: webview, key: "a", modifiers: ["command"])
        BrowserJSInputDispatcher.type(in: webview, text: value)
        if await readValue(ref) == value { return }

        _ = await eval(AutofillFieldQuery.setValueJS(ref, value: value))
    }

    private func readValue(_ ref: AutofillFieldQuery.FieldRef) async -> String? {
        await eval(AutofillFieldQuery.readValueJS(ref)) as? String
    }

    private func restoreWebviewFocus() {
        guard let webview else { return }
        if BrowserStore.shared.model.isTargetFocused(.webContent(webContentID)) {
            webview.wowser_becomeFirstResponder(asTarget: .webContent(webContentID))
        } else {
            webview.window?.makeFirstResponderIfNeeded(webview)
        }
    }

    // MARK: - Agent hook

    /// BrowserJS `credentials.fillPassword`: type the saved password for
    /// `username` (or the site's only/most-used login) into the password field
    /// that currently has focus in this page. The password never leaves the
    /// app. Returns the username whose password was filled.
    public func fillPasswordForAgent(username: String?, domain: String?) async throws -> String {
        guard AutofillSettings.agentsMayFillPasswords else { throw BrowserJSError.underlying("Password autofill for agents is disabled in Settings → Autofill") }
        guard let profileID else { throw BrowserJSError.underlying("no profile for tab") }
        let result = await eval(AutofillFieldQuery.snapshotActiveJS)
        guard let snap = AutofillFieldQuery.parseSnapshot(result), let active = snap.active, active.isPasswordInput else {
            throw BrowserJSError.underlying("the focused element is not a password field — click into the password field first")
        }
        guard AutofillHostMatcher.isFillableURL(snap.url), let host = snap.url?.host else { throw BrowserJSError.underlying("not a web page") }
        if let domain, !AutofillHostMatcher.credential(domain: domain, appliesTo: host) {
            throw BrowserJSError.underlying("page host \(host) does not match \(domain)")
        }
        let data = AutofillStore.shared.data(for: profileID)
        let candidates = data.credentials(forHost: host)
        let credential: AutofillCredential?
        if let username {
            credential = candidates.first { $0.username.lowercased() == username.lowercased() }
        } else {
            credential = candidates.first
        }
        guard let credential else { throw BrowserJSError.underlying("no saved password for \(host)\(username.map { " and username \($0)" } ?? "")") }
        guard let password = await AutofillStore.shared.password(for: credential, profile: profileID) else {
            throw BrowserJSError.underlying("password for \(credential.username) is missing from the keychain")
        }
        apply(snapshot: snap)
        menu = nil
        await fill(field: active, value: password)
        AutofillStore.shared.markUsed(.credential(credential), profile: profileID)
        return credential.username
    }

    // MARK: - Form capture (remembering what was submitted)

    private struct FormCapture {
        var url: URL
        var entries: [CapturedEntry]
        var activeRef: AutofillFieldQuery.FieldRef
        var hasPassword: Bool
        var updatedAt: Date
    }
    private struct CapturedEntry {
        var kind: AutofillFieldKind
        var name: String
        var value: String
    }
    private var formCapture: FormCapture?
    private var submitCandidateAt: Date?
    private var submitChecks: [Task<Void, Never>] = []

    private func updateFormCapture() {
        guard AutofillSettings.remembersForms, let url = pageURL, AutofillHostMatcher.isFillableURL(url), let active = activeClassified else { return }
        let entries = classifiedForm.compactMap { f -> CapturedEntry? in
            guard let k = f.kind, let v = f.descriptor.value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return CapturedEntry(kind: k, name: f.descriptor.name, value: v)
        }
        guard !entries.isEmpty else { return }
        formCapture = FormCapture(
            url: url,
            entries: entries,
            activeRef: AutofillFieldQuery.FieldRef(active.descriptor),
            hasPassword: classifiedForm.contains { $0.kind?.isPassword == true },
            updatedAt: Date()
        )
    }

    /// Re-reads the form's values right now (before a Return / click reaches
    /// the page) and arms the submission checks.
    private func captureFormNow(reason: String, at point: CGPoint? = nil) {
        guard AutofillSettings.remembersForms else { return }
        let ref: AutofillFieldQuery.FieldRef
        if let active = lastSnapshot?.active, active.tag == "input" { ref = AutofillFieldQuery.FieldRef(active) }
        else if let c = formCapture, Date().timeIntervalSince(c.updatedAt) < 600 { ref = c.activeRef }
        else { return }
        submitCandidateAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.eval(AutofillFieldQuery.snapshotFieldJS(ref))
            guard let snap = AutofillFieldQuery.parseSnapshot(result), snap.active != nil else { return }
            let classified = AutofillFieldClassifier.classify(fields: snap.form.isEmpty ? [snap.active!] : snap.form)
            let entries = classified.compactMap { f -> CapturedEntry? in
                guard let k = f.kind, let v = f.descriptor.value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return CapturedEntry(kind: k, name: f.descriptor.name, value: v)
            }
            guard !entries.isEmpty, let url = snap.url ?? self.pageURL else { return }
            self.formCapture = FormCapture(url: url, entries: entries, activeRef: ref, hasPassword: classified.contains { $0.kind?.isPassword == true }, updatedAt: Date())
            self.armSubmissionChecks()
        }
    }

    /// SPA logins never navigate: poll briefly after a submit-like action and
    /// treat "the form's password field is gone" as a successful submit.
    private func armSubmissionChecks() {
        submitChecks.forEach { $0.cancel() }
        submitChecks = [1.2, 3.5].map { delay in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, let capture = self.formCapture, self.submitCandidateAt != nil else { return }
                let result = await self.eval(AutofillFieldQuery.snapshotFieldJS(capture.activeRef))
                let snap = AutofillFieldQuery.parseSnapshot(result)
                let fieldGone = snap?.active == nil || (snap?.active?.rect.map { $0.width <= 0 || $0.height <= 0 } ?? true)
                let passwordGone = capture.hasPassword && !(snap?.form.contains { $0.isPasswordInput && ($0.rect?.width ?? 0) > 0 } ?? false)
                let urlChanged = (snap?.url?.absoluteString ?? capture.url.absoluteString) != capture.url.absoluteString
                if fieldGone || passwordGone || urlChanged {
                    self.finalizeSubmission()
                }
            }
        }
    }

    /// Main-frame navigation committed.
    public func pageDidNavigate(to url: URL?) {
        if let submitCandidateAt, Date().timeIntervalSince(submitCandidateAt) < 20, formCapture != nil {
            finalizeSubmission()
        }
        formCapture = nil
        submitCandidateAt = nil
        submitChecks.forEach { $0.cancel() }
        submitChecks = []
        pendingClick = nil
        menu = nil
        selectMenu = nil
        dismissedFieldSignature = nil
        selectRects = []
        lastSnapshot = nil
        classifiedForm = []
        activeClassified = nil
        pageURL = url
    }

    /// WebKit's form client told us a form is being submitted (classic
    /// navigations only). `values` maps field names to values.
    public func formWillSubmit(values: [String: String]) {
        guard AutofillSettings.remembersForms else { return }
        if var capture = formCapture, Date().timeIntervalSince(capture.updatedAt) < 600 {
            for i in capture.entries.indices {
                if !capture.entries[i].name.isEmpty, let v = values[capture.entries[i].name], !v.isEmpty {
                    capture.entries[i].value = v
                }
            }
            formCapture = capture
            finalizeSubmission()
        }
    }

    private func finalizeSubmission() {
        guard let capture = formCapture else { return }
        formCapture = nil
        submitCandidateAt = nil
        submitChecks.forEach { $0.cancel() }
        submitChecks = []
        guard let profileID else { return }
        let submission = AutofillFormSubmission(url: capture.url, entries: capture.entries.map { .init(kind: $0.kind, value: $0.value) })
        let windowID = self.windowID
        Task { await AutofillStore.shared.handleSubmission(submission, profile: profileID, windowID: windowID) }
    }

    // MARK: - JS

    private func eval(_ js: String) async -> Any? {
        guard let webview else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
            webview.evaluateJavaScript(js) { value, error in
                if let error { print("[autofill] query failed: \(error.localizedDescription)") }
                cont.resume(returning: error == nil ? value : nil)
            }
        }
    }
}

// MARK: - Native text insertion

extension WKWebView {
    /// Inserts `text` at the page's current selection through WebKit's
    /// `NSTextInputClient` implementation — the same path an IME or dictation
    /// uses — so the page gets real `beforeinput`/`input` events.
    func wowser_insertText(_ text: String) {
        let sel = #selector(NSTextInputClient.insertText(_:replacementRange:))
        guard responds(to: sel), let imp = method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(self, sel, text as NSString, NSRange(location: NSNotFound, length: 0))
    }
}

extension NSWindow {
    func makeFirstResponderIfNeeded(_ responder: NSResponder) {
        if firstResponder !== responder { makeFirstResponder(responder) }
    }
}

extension AutofillFieldQuery {
    /// Last-resort fill: the element's own value setter + an `input` event.
    static func setValueJS(_ ref: FieldRef, value: String) -> String {
        let lit = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function() {
            const r = \(ref.jsArgs);
            let doc = document;
            for (const i of r.framePath) { const f = doc.querySelectorAll('iframe')[i]; if (!f || !f.contentDocument) return false; doc = f.contentDocument; }
            const el = doc.querySelectorAll('input, textarea, select')[r.fieldIndex];
            if (!el) return false;
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value');
            if (setter && setter.set) setter.set.call(el, \(lit)); else el.value = \(lit);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        })()
        """
    }
}
#endif
