#if os(macOS)
import Foundation
import AppKit
import Combine

// MARK: - Dictation
//
// ⌘D (or the mic button) starts a dictation session aimed at one of two targets:
//
//  • a text field focused in the current page (`WebContent.Info.focusedEditable`
//    is non-nil) — the transcript is inserted into that field on commit,
//    optionally cleaned up by the configured LLM first (streamed in);
//  • otherwise the omnibox — the transcript becomes a question for the agent
//    (`AgentChatTabs.ask(dictated: true)`). On a new-tab page this is the big
//    centered input.
//
// While listening: Return / ⌘D / clicking the mic commits, Escape cancels.
// Views observe this controller to draw the target outline and live transcript.

@MainActor
public final class DictationController: ObservableObject {
    public static let shared = DictationController()

    public enum Target: Equatable {
        /// A focused editable element inside a page.
        case webField(pane: ID<WebContent>, field: WebContent.Info.FocusedEditable)
        /// The address bar of `pane` (nil pane = window with no tab) → agent.
        case omnibox(pane: ID<WebContent>?, window: ID<WindowState>)
        /// A native terminal tab: text is typed into its PTY.
        case terminal(pane: ID<WebContent>)
        /// A native agent-chat tab: the transcript is sent as a message.
        case agentChat(pane: ID<WebContent>, sessionKey: String)

        public var paneID: ID<WebContent>? {
            switch self {
            case .webField(let pane, _): return pane
            case .omnibox(let pane, _): return pane
            case .terminal(let pane): return pane
            case .agentChat(let pane, _): return pane
            }
        }
        public var isOmnibox: Bool { if case .omnibox = self { return true } else { return false } }
    }

    public enum Phase: Equatable {
        case idle
        case starting
        case listening
        /// Waiting for the recognizer's final pass / the LLM cleanup stream.
        case committing
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var target: Target?
    @Published public private(set) var transcript = ""
    @Published public private(set) var errorText: String?
    /// The mic button is hovered for this pane: preview where dictation would go.
    @Published public private(set) var hoverPreview: Target?

    private var transcriber: SpeechTranscriber?
    private var keyMonitor: Any?
    private var errorClearTask: Task<Void, Never>?

    private init() {}

    public var isActive: Bool { phase != .idle }

    /// The target dictation would use right now for `paneID`, given current state.
    public func resolveTarget(paneID: ID<WebContent>?, windowID: ID<WindowState>) -> Target {
        let state = BrowserStore.shared.model
        // The user is typing in the search bar: that's where dictation goes,
        // regardless of what the page last had focused.
        let focus = state.focusState(windowID: windowID).target
        if case .omnibox = focus { return .omnibox(pane: paneID, window: windowID) }
        if case .emptyWindowOmnibox = focus { return .omnibox(pane: paneID, window: windowID) }
        if let paneID, let pane = state.pane(forId: paneID) {
            if let url = pane.info.url, let key = NativePageKey(url: url) {
                if key.isTerminal { return .terminal(pane: paneID) }
                if case .agent(let sessionKey, _) = key { return .agentChat(pane: paneID, sessionKey: sessionKey) }
            }
            if let field = pane.info.focusedEditable, !pane.info.isEmptyPage {
                return .webField(pane: paneID, field: field)
            }
        }
        return .omnibox(pane: paneID, window: windowID)
    }

    // MARK: - Hover preview

    public func setHoverPreview(paneID: ID<WebContent>?, windowID: ID<WindowState>?, hovering: Bool) {
        guard !isActive else { hoverPreview = nil; return }
        if hovering, let windowID {
            hoverPreview = resolveTarget(paneID: paneID, windowID: windowID)
        } else {
            hoverPreview = nil
        }
    }

    // MARK: - Session control

    /// ⌘D / mic click: start when idle, commit when listening.
    public func toggle(paneID: ID<WebContent>?, windowID: ID<WindowState>) {
        switch phase {
        case .idle:
            start(target: resolveTarget(paneID: paneID, windowID: windowID))
        case .listening:
            commit()
        case .starting, .committing:
            break
        }
    }

    public func start(target: Target) {
        guard phase == .idle else { return }
        hoverPreview = nil
        self.target = target
        transcript = ""
        errorText = nil
        phase = .starting
        Task { @MainActor in
            do {
                try await SpeechTranscriber.requestPermissions()
                guard phase == .starting else { return } // cancelled meanwhile
                let t = SpeechTranscriber()
                t.onTranscript = { [weak self] text, _ in
                    guard let self, self.phase == .listening || self.phase == .committing else { return }
                    self.transcript = text
                }
                t.onError = { [weak self] error in
                    self?.fail(error.localizedDescription)
                }
                try t.start()
                transcriber = t
                phase = .listening
                installKeyMonitor()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// End the session and deliver the transcript to the target.
    public func commit() {
        guard phase == .listening, let target, let transcriber else { return }
        phase = .committing
        removeKeyMonitor()
        Task { @MainActor in
            let text = await transcriber.finish()
            self.transcriber = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = trimmed
            guard !trimmed.isEmpty else {
                finish()
                return
            }
            switch target {
            case .omnibox(_, let windowID):
                finish()
                AgentChatTabs.ask(query: trimmed, windowID: windowID, dictated: true)
            case .webField(let paneID, _):
                await deliverToWebField(paneID: paneID, raw: trimmed)
                finish()
            case .terminal(let paneID):
                deliverToTerminal(paneID: paneID, text: trimmed)
                finish()
            case .agentChat(_, let sessionKey):
                finish()
                AgentChatSession.session(forKey: sessionKey).send(text: trimmed)
            }
        }
    }

    public func cancel() {
        guard isActive else { return }
        transcriber?.stop()
        transcriber = nil
        removeKeyMonitor()
        finish()
    }

    private func finish() {
        phase = .idle
        target = nil
        transcript = ""
    }

    private func fail(_ message: String) {
        transcriber?.stop()
        transcriber = nil
        removeKeyMonitor()
        finish()
        errorText = message
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.errorText = nil }
        }
    }

    // MARK: - Keys while listening

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.phase == .listening else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // Return / Enter
                self.commit()
                return nil
            case 53: // Escape
                self.cancel()
                return nil
            default:
                if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
                    self.commit()
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Typing into a terminal

    /// Sends the transcript to the terminal's PTY as typed input (no newline —
    /// the user reviews and presses Return themselves).
    private func deliverToTerminal(paneID: ID<WebContent>, text: String) {
        guard let wc = BrowserStore.shared.existingWebContent(forId: paneID),
              let session = wc.overlayObject as? TerminalSession else { return }
        wc.focus()
        session.view.send(txt: text)
    }

    // MARK: - Inserting into a page

    private func deliverToWebField(paneID: ID<WebContent>, raw: String) async {
        guard let winID = BrowserStore.shared.model.windowContaining(webContentId: paneID)?.id,
              let wc = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: winID),
              let webview = wc.wkWebview else { return }
        // Make sure the page (and its field) has keyboard focus again — the
        // user may have clicked the mic button.
        wc.focus()

        if DefaultsKeys.dictationCleanup.boolValue(), let llm = LLMs.current(json: false) {
            let context = await DictationCleanup.captureContext(webview: webview)
            var inserted = ""
            var firstChunk = true
            do {
                for try await cleaned in DictationCleanup.stream(raw: raw, context: context, llm: llm) {
                    // Stream in: insert only the newly arrived suffix.
                    guard cleaned.hasPrefix(inserted) else { continue }
                    let delta = String(cleaned.dropFirst(inserted.count))
                    guard !delta.isEmpty else { continue }
                    await Self.insertText(delta, into: webview, leadingSpaceIfNeeded: firstChunk)
                    firstChunk = false
                    inserted = cleaned
                }
                if inserted.isEmpty {
                    await Self.insertText(raw, into: webview, leadingSpaceIfNeeded: true)
                }
            } catch {
                // Cleanup failed: fall back to whatever we haven't inserted yet.
                if inserted.isEmpty {
                    await Self.insertText(raw, into: webview, leadingSpaceIfNeeded: true)
                }
            }
        } else {
            await Self.insertText(raw, into: webview, leadingSpaceIfNeeded: true)
        }
    }

    /// Inserts `text` at the caret of the page's focused editable element.
    /// `execCommand('insertText')` goes through the editing pipeline (undo,
    /// input events, React-style listeners); we fall back to a value splice
    /// when a page refuses it.
    static func insertText(_ text: String, into webview: WebContentWebView, leadingSpaceIfNeeded: Bool) async {
        let lit = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let js = """
        (() => {
            let text = \(lit);
            let el = document.activeElement;
            for (let i = 0; i < 4 && el && el.tagName === 'IFRAME'; i++) {
                try { el = el.contentDocument && el.contentDocument.activeElement; } catch (_) { el = null; }
            }
            if (!el) return false;
            const isField = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
            if (\(leadingSpaceIfNeeded) && isField) {
                const s = el.selectionStart ?? el.value.length;
                const before = el.value.slice(0, s);
                if (before.length > 0 && !/\\s$/.test(before)) text = ' ' + text;
            }
            let ok = false;
            try { ok = (el.ownerDocument || document).execCommand('insertText', false, text); } catch (_) {}
            if (!ok && isField && typeof el.setRangeText === 'function') {
                const s = el.selectionStart ?? el.value.length, e = el.selectionEnd ?? s;
                el.setRangeText(text, s, e, 'end');
                el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
                ok = true;
            }
            return ok;
        })()
        """
        _ = try? await webview.evalReturningValue(js)
    }
}
#endif
