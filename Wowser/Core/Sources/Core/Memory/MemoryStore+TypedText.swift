import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

// Text the user types into web pages. A local key-down monitor feeds a
// per-pane buffer that replays backspace / forward-delete / arrow keys so the
// stored text is what ended up in the field, not a keystroke log. Buffers
// flush after a pause, when the typing target changes, or when they grow
// large. Sensitive fields (password, card, OTP — see `refreshFocusedEditableNow`)
// are never captured, nor is anything typed with Cmd/Ctrl held.

extension MemoryStore {

    struct TypingTarget: Equatable {
        var paneID: ID<WebContent>
        var scope: UUID
        var url: URL?
        var title: String?
        var tabID: ID<Tab>?
        var sensitive: Bool
        var spaceID: String?
        var spaceName: String?
    }

    final class TypedBuffer {
        var target: TypingTarget
        var chars: [Character] = []
        var cursor = 0
        var flushTimer: Timer?
        init(target: TypingTarget) { self.target = target }
    }

    private static var keyMonitor: Any?              // main-only
    private static var targets: [TypingTarget] = []   // main-only; one per window with a focused editable
    private static var buffer: TypedBuffer?           // main-only
    private static var targetSubscription: AnyCancellable?

    func startTypedTextCapture() {
        #if os(macOS)
        guard Self.keyMonitor == nil else { return }
        // Which panes could receive typing right now, recomputed only when
        // the relevant slice of state changes — so the key handler itself
        // touches no store.
        Self.targetSubscription = BrowserStore.shared.uiPublisher
            .map { state -> [TypingTarget] in
                state.windows.values.compactMap { win -> TypingTarget? in
                    guard case .webContent(let paneID)? = state.focusState(windowID: win.id).target,
                          let pane = state.pane(forId: paneID), let editable = pane.info.focusedEditable,
                          let profile = state.profile(forWebContentId: paneID) else { return nil }
                    return TypingTarget(paneID: paneID, scope: profile.dataStoreUUID, url: pane.info.url, title: pane.info.title,
                                        tabID: state.paneToTabMapping[paneID], sensitive: editable.sensitive == true,
                                        spaceID: profile.id.raw, spaceName: profile.displayName)
                }
            }
            .removeDuplicates()
            .sink { [weak self] targets in
                Self.targets = targets
                // Target moved away from the buffered pane: flush what we have.
                if let buf = Self.buffer, !targets.contains(where: { $0.paneID == buf.target.paneID && !$0.sensitive }) {
                    self?.flushTypedBuffer()
                }
            }
        Self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        #endif
    }

    func stopTypedTextCapture() {
        #if os(macOS)
        flushTypedBuffer()
        if let m = Self.keyMonitor { NSEvent.removeMonitor(m) }
        Self.keyMonitor = nil
        Self.targetSubscription = nil
        Self.targets = []
        #endif
    }

    #if os(macOS)
    private func handleKeyDown(_ event: NSEvent) {
        guard isActive, !Self.targets.isEmpty else { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return }
        // Pick the target whose webview lives in the key window.
        let target: TypingTarget? = Self.targets.count == 1 ? Self.targets[0] : Self.targets.first { t in
            BrowserStore.shared.existingWebContent(forId: t.paneID)?.wkWebview?.window?.isKeyWindow == true
        }
        guard let target, !target.sensitive, isEnabled(target.scope) else { return }

        if let buf = Self.buffer, buf.target.paneID != target.paneID { flushTypedBuffer() }
        let buf = Self.buffer ?? TypedBuffer(target: target)
        buf.target = target
        Self.buffer = buf

        switch event.keyCode {
        case 51: // delete
            if buf.cursor > 0 { buf.chars.remove(at: buf.cursor - 1); buf.cursor -= 1 }
        case 117: // forward delete
            if buf.cursor < buf.chars.count { buf.chars.remove(at: buf.cursor) }
        case 123: buf.cursor = max(0, buf.cursor - 1)               // left
        case 124: buf.cursor = min(buf.chars.count, buf.cursor + 1) // right
        case 115: buf.cursor = 0                                    // home
        case 119: buf.cursor = buf.chars.count                      // end
        case 36, 76: insert("\n", into: buf)                        // return / enter
        case 48: break                                              // tab
        case 53, 126, 125, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113: break // esc, up/down, F-keys
        default:
            guard let chars = event.characters, !chars.isEmpty else { return }
            for c in chars where !(c.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) {
                insert(c, into: buf)
            }
        }
        if buf.chars.count > 20_000 { flushTypedBuffer(); return }
        buf.flushTimer?.invalidate()
        buf.flushTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.flushTypedBuffer() }
    }

    private func insert(_ c: Character, into buf: TypedBuffer) {
        buf.chars.insert(c, at: buf.cursor)
        buf.cursor += 1
    }
    #endif

    func flushTypedBuffer() {
        guard let buf = Self.buffer else { return }
        buf.flushTimer?.invalidate()
        Self.buffer = nil
        let text = String(buf.chars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        let t = buf.target
        var event = MemoryEvent(kind: "typed", pageType: Self.pageType(for: t.url), paneID: t.paneID.raw, tabID: t.tabID?.raw,
                                url: t.url, title: t.title, text: text)
        event.spaceID = t.spaceID; event.spaceName = t.spaceName
        record(scope: t.scope, event)
    }
}
