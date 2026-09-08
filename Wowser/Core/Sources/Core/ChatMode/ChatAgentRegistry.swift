import Foundation

// Who's who among chat-mode agents.
//
// Session keys carry identity:
//   - "chatspace-<profileID>"  the coordinator of a chat-mode space (see ChatSpaceSession)
//   - "sub-<id>"               a subagent tab spawned via `browser.agents.spawn`
//   - "agenttab-<id>"          an ordinary "ask agent" tab (AgentChatTabs)
//
// The registry remembers parent/child links and names for subagents (in
// memory only — a subagent that outlives a restart still knows its parent from
// its stored system prompt, but the parent won't list it). It also resolves
// "who is calling" for the BrowserJS chat tools, which only carry a key.

@MainActor
enum ChatAgentRegistry {
    static let coordinatorPrefix = "chatspace-"
    static let subagentPrefix = "sub-"

    struct Record {
        var key: String
        var name: String
        var parentKey: String?
        var paneID: ID<WebContent>?
        /// Set when the subagent called `agents.send` at its parent during the
        /// current turn; cleared at turn start. See AgentChatSession.turnDidEnd.
        var reportedToParentThisTurn = false
    }

    private(set) static var records: [String: Record] = [:]

    static func coordinatorKey(for profileID: ID<Profile>) -> String {
        coordinatorPrefix + profileID.raw
    }

    static func profileID(forCoordinatorKey key: String) -> ID<Profile>? {
        guard key.hasPrefix(coordinatorPrefix) else { return nil }
        return ID<Profile>(raw: String(key.dropFirst(coordinatorPrefix.count)))
    }

    static func isSubagentKey(_ key: String) -> Bool { key.hasPrefix(subagentPrefix) }

    static func register(key: String, name: String, parentKey: String?, paneID: ID<WebContent>?) {
        records[key] = Record(key: key, name: name, parentKey: parentKey, paneID: paneID)
    }

    static func unregister(key: String) {
        records[key] = nil
    }

    static func record(forKey key: String) -> Record? { records[key] }

    static func markReportedToParent(key: String) {
        records[key]?.reportedToParentThisTurn = true
    }

    static func resetTurnFlags(key: String) {
        records[key]?.reportedToParentThisTurn = false
    }

    static func children(of parentKey: String) -> [Record] {
        records.values.filter { $0.parentKey == parentKey }.sorted { $0.key < $1.key }
    }

    /// Human label for a key, for "message from X" rows and prompts.
    static func displayName(forKey key: String) -> String {
        if let r = records[key] { return r.name }
        if let pid = profileID(forCoordinatorKey: key) {
            let profile = BrowserStore.shared.model.profiles[pid]
            let title = profile?.title?.nilIfEmpty ?? profile?.autoTitle ?? "space"
            return "Coordinator (\(title))"
        }
        return key
    }

    /// Where a calling agent's things go.
    struct CallerContext {
        /// The calling agent's key (nil for the MCP runtime).
        var key: String?
        /// The chat-mode space whose thread should receive cards, if the caller
        /// is a coordinator (or an outside caller while a chat-mode space is up).
        var threadProfileID: ID<Profile>?
        /// The caller's own tab pane, for subagents.
        var ownPaneID: ID<WebContent>?
        var parentKey: String?
        /// The window to act in.
        var windowID: ID<WindowState>?
    }

    static func callerContext(agentKey: String?) -> CallerContext {
        let state = BrowserStore.shared.model
        let currentWindow = state.windowsMostRecentFirst.first
        var ctx = CallerContext(key: agentKey, windowID: currentWindow?.id)

        if let agentKey, let pid = profileID(forCoordinatorKey: agentKey) {
            ctx.threadProfileID = pid
            // Prefer a window showing that space.
            if let win = state.windowsMostRecentFirst.first(where: { $0.profile == pid }) {
                ctx.windowID = win.id
            }
            return ctx
        }
        if let agentKey, let paneID = state.agentChatPane(forKey: agentKey) {
            ctx.ownPaneID = paneID
            ctx.parentKey = records[agentKey]?.parentKey
            if let win = state.windowContaining(webContentId: paneID) {
                ctx.windowID = win.id
                if state.profiles[win.profile]?.isChatMode == true {
                    ctx.threadProfileID = win.profile
                }
            }
            return ctx
        }
        // Outside caller (MCP) or unknown key: the current window's space, if
        // it's in chat mode.
        if let win = currentWindow, state.profiles[win.profile]?.isChatMode == true {
            ctx.threadProfileID = win.profile
        }
        return ctx
    }
}
