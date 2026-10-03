import Foundation
#if os(macOS)
import AppKit
#endif

// `browser.toast.*`: lets an agent get the user's attention while it runs in
// the background. Toasts show in the frontmost window (not the agent's own),
// since the user is likely looking at something else. Action buttons — and
// closing a sticky toast — reply to the agent: a message into its chat, or
// typed into the terminal running `claude`. See ToastActions.swift.

extension BrowserJSLiveHost {
    static let toastMaxMessage = 160
    static let toastMaxTitle = 60
    static let toastMaxActionTitle = 24
    static let toastMaxActions = 3

    public func toastShow(agentKey: String?, message: String, title: String?, icon: String?, actions: [String], sticky: Bool, durationMs: Int?) async throws -> BrowserJSToastInfo {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let actions = actions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !message.isEmpty else { throw BrowserJSError.invalidArgs("message is empty") }
        guard message.count <= Self.toastMaxMessage else {
            throw BrowserJSError.invalidArgs("message is \(message.count) chars; keep it under \(Self.toastMaxMessage) — one short sentence")
        }
        if let title, title.count > Self.toastMaxTitle {
            throw BrowserJSError.invalidArgs("title is \(title.count) chars; keep it under \(Self.toastMaxTitle)")
        }
        guard actions.count <= Self.toastMaxActions else {
            throw BrowserJSError.invalidArgs("at most \(Self.toastMaxActions) actions")
        }
        if let bad = actions.first(where: { $0.isEmpty || $0.count > Self.toastMaxActionTitle }) {
            throw BrowserJSError.invalidArgs("action \"\(bad)\" must be 1–\(Self.toastMaxActionTitle) chars, e.g. \"Approve\", \"Retry\"")
        }
        let wantsReply = sticky || !actions.isEmpty
        if wantsReply && title == nil {
            throw BrowserJSError.invalidArgs("toasts with actions or sticky: true need a `title` naming your task (the user may be multitasking)")
        }

        return try await Task { @MainActor in
            let state = BrowserStore.shared.model
            var target: AgentToastReplyTarget?
            if let agentKey {
                target = .agent(key: agentKey)
            } else if let origin = BrowserJSCallOrigin.paneID,
                      let url = state.pane(forId: origin)?.info.url,
                      NativePageKey(url: url)?.isTerminal == true {
                target = .terminal(pane: origin)
            }
            if wantsReply && target == nil {
                throw BrowserJSError.invalidArgs("this caller can't receive toast replies (not an in-browser agent or terminal); use a plain toast without actions")
            }
            guard let windowID = state.windowsMostRecentFirst.first?.id else {
                throw BrowserJSError.windowNotFound("frontmost")
            }

            var toast = Toast(
                message: message,
                icon: Self.validIcon(icon) ?? (sticky ? "hand.raised.fill" : "sparkles"),
                dismissAfter: durationMs.map { max(1, Double($0) / 1000) }
            )
            toast.title = title
            toast.sticky = sticky ? true : nil
            if let target {
                toast.actions = actions.map {
                    ToastAction(title: $0, kind: .agentReply(target: target, toast: message, choice: $0))
                }
                if sticky {
                    toast.onDismiss = .agentReply(target: target, toast: message, choice: nil)
                }
            }
            BrowserStore.shared.modify { $0.addToast(toast, in: windowID) }
            return BrowserJSToastInfo(id: toast.id.uuidString)
        }.value
    }

    public func toastDismiss(id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { throw BrowserJSError.invalidArgs("id") }
        BrowserStore.shared.modify { state in
            for windowID in state.windows.keys {
                state.removeToast(id: uuid, in: windowID)
            }
        }
    }

    private static func validIcon(_ name: String?) -> String? {
        guard let name else { return nil }
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : nil
        #else
        return name
        #endif
    }
}
