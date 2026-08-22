import Foundation
import ChatToys

// Lets the browser agent read and modify browser state (tabs, groups, etc)
final class BrowserControlTool: Tool {
    private weak var session: BrowserAgentSession?

    // Short, stable ids (t1, t2...) presented to the model in place of raw tab UUIDs
    private var shortIdToTab = [String: ID<Tab>]()
    private var tabToShortId = [ID<Tab>: String]()
    private var nextShortId = 1

    init(session: BrowserAgentSession) {
        self.session = session
    }

    var functions: [LLMFunction] {
        [Self.listTabsFn.asLLMFunction, Self.setTabGroupsFn.asLLMFunction, Self.closeTabsFn.asLLMFunction, Self.openURLFn.asLLMFunction, Self.showToUserFn.asLLMFunction]
    }

    // MARK: - Functions

    static let listTabsFn = TypedFunction<ListTabsArgs>(name: "list_tabs", description: "Returns the current list of open tabs and their groups. Use to refresh your view of the browser after making changes.", type: ListTabsArgs.self)
    struct ListTabsArgs: FunctionArgs {
        static var schema: [String: LLMFunction.JsonSchema] { [:] }
    }

    static let setTabGroupsFn = TypedFunction<SetTabGroupsArgs>(name: "set_tab_groups", description: "Assigns tabs to named groups (used to organize the sidebar, or rename groups by reassigning their tabs). Tabs with the same group name are shown together under that name. Pass an empty group name to ungroup a tab.", type: SetTabGroupsArgs.self)
    struct SetTabGroupsArgs: FunctionArgs {
        var tab_ids: [String]
        var group_names: [String]

        static var schema: [String: LLMFunction.JsonSchema] {
            [
                "tab_ids": .array(description: "Tab ids to assign (e.g. ['t1', 't2'])", itemType: .string(description: "A tab id from list_tabs")),
                "group_names": .array(description: "Group name for each tab id, in the same order. Short (1-3 word) sentence-case names. Empty string = no group.", itemType: .string(description: "Group name"))
            ]
        }
    }

    static let closeTabsFn = TypedFunction<CloseTabsArgs>(name: "close_tabs", description: "Closes the given tabs (e.g. duplicates or tabs the user asked to clean up). Pinned tabs are not closed.", type: CloseTabsArgs.self)
    struct CloseTabsArgs: FunctionArgs {
        var tab_ids: [String]

        static var schema: [String: LLMFunction.JsonSchema] {
            [
                "tab_ids": .array(description: "Tab ids to close", itemType: .string(description: "A tab id from list_tabs"))
            ]
        }
    }

    static let openURLFn = TypedFunction<OpenURLArgs>(name: "open_url", description: "Opens a URL in a new background tab.", type: OpenURLArgs.self)
    struct OpenURLArgs: FunctionArgs {
        var url: String

        static var schema: [String: LLMFunction.JsonSchema] {
            [
                "url": .string(description: "Full URL to open, including scheme")
            ]
        }
    }

    static let showToUserFn = TypedFunction<ShowToUserArgs>(name: "show_to_user", description: "Reveals your tab to the user. Only call this if you genuinely need their attention (something to show, or a problem you can't resolve).", type: ShowToUserArgs.self)
    struct ShowToUserArgs: FunctionArgs {
        var message: String

        static var schema: [String: LLMFunction.JsonSchema] {
            [
                "message": .string(description: "Short explanation of why you need the user's attention")
            ]
        }
    }

    // MARK: - Handling

    func contextToInsertAtBeginningOfThread(context: ToolContext) async throws -> String? {
        await browserStateDescription()
    }

    func handleCallIfApplicable(_ call: LLMMessage.FunctionCall, context: ToolContext) async throws -> TaggedLLMMessage.FunctionResponse? {
        if Self.listTabsFn.checkMatch(call: call) != nil {
            let desc = await browserStateDescription()
            return call.response(text: desc)
        }
        if let args = Self.setTabGroupsFn.checkMatch(call: call) {
            let result = await setTabGroups(tabIds: args.tab_ids, groupNames: args.group_names)
            return call.response(text: result)
        }
        if let args = Self.closeTabsFn.checkMatch(call: call) {
            let result = await closeTabs(tabIds: args.tab_ids)
            return call.response(text: result)
        }
        if let args = Self.openURLFn.checkMatch(call: call) {
            let result = await openURL(args.url)
            return call.response(text: result)
        }
        if let args = Self.showToUserFn.checkMatch(call: call) {
            let result = await showToUser(message: args.message)
            return call.response(text: result)
        }
        return nil
    }

    // MARK: - Implementations (main thread)

    @MainActor
    private func targetWindowID() -> ID<WindowState>? {
        let state = BrowserStore.shared.model
        if let winID = session?.windowID, state.windows[winID] != nil {
            return winID
        }
        return state.activeWindow?.id
    }

    @MainActor
    private func shortId(forTab id: ID<Tab>) -> String {
        if let existing = tabToShortId[id] {
            return existing
        }
        let short = "t\(nextShortId)"
        nextShortId += 1
        tabToShortId[id] = short
        shortIdToTab[short] = id
        return short
    }

    @MainActor
    private func browserStateDescription() -> String {
        let state = BrowserStore.shared.model
        guard let windowID = targetWindowID(), let window = state.windows[windowID] else {
            return "# Current browser state\nNo browser window is open."
        }
        var lines = ["# Current browser state", "Open tabs, in sidebar order:"]
        let favorites = state.favorites(profileId: window.profile)
        for tabId in state.tabsInVisibleOrder(inWindow: windowID) {
            guard let tab = state.tabs[tabId] else { continue }
            let short = shortId(forTab: tabId)
            let info = tab.panes.first?.info
            var line = "- [\(short)] \(info?.title?.nilIfEmpty ?? "Untitled") — \(info?.url?.absoluteString ?? "no url")"
            if let group = tab.aiTags?.groupName {
                line += " (group: \(group))"
            }
            if favorites.contains(tabId) {
                line += " (pinned)"
            }
            if window.currentTab == tabId {
                line += " (currently active)"
            }
            lines.append(line)
        }
        let groups = state.existingGroupNames(in: windowID)
        if !groups.isEmpty {
            lines.append("Existing group names: \(groups.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func setTabGroups(tabIds: [String], groupNames: [String]) -> String {
        guard tabIds.count == groupNames.count else {
            return "Error: tab_ids and group_names must have the same length."
        }
        guard let windowID = targetWindowID() else {
            return "Error: no browser window is open."
        }
        var applied = 0
        var unknown = [String]()
        BrowserStore.shared.modify { state in
            for (shortId, groupName) in zip(tabIds, groupNames) {
                guard let tabId = self.shortIdToTab[shortId], state.tabs[tabId] != nil else {
                    unknown.append(shortId)
                    continue
                }
                state.modifyTab(id: tabId) { tab in
                    let historyKey = tab.panes.first?.info.url?.historyKey ?? ""
                    tab.aiTags = AITags(historyKeyWhenFetched: historyKey, groupName: groupName.nilIfEmpty)
                }
                applied += 1
            }
            // Reorder so groups sit together in the sidebar
            var windowTabs = state.windows[windowID]?.tabs ?? []
            state.orderTabIdsToColocateGroups(ids: &windowTabs)
            state.windows[windowID]?.tabs = windowTabs
        }
        var result = "Assigned groups for \(applied) tabs and reordered the sidebar."
        if !unknown.isEmpty {
            result += " Unknown tab ids: \(unknown.joined(separator: ", "))."
        }
        return result
    }

    @MainActor
    private func closeTabs(tabIds: [String]) -> String {
        let state = BrowserStore.shared.model
        // Identify panes to close outside the modify block
        var paneIdsToClose = [ID<WebContent>]()
        var unknown = [String]()
        for shortId in tabIds {
            guard let tabId = self.shortIdToTab[shortId], let tab = state.tabs[tabId] else {
                unknown.append(shortId)
                continue
            }
            paneIdsToClose.append(contentsOf: tab.panes.map(\.id))
        }
        for paneId in paneIdsToClose {
            BrowserStore.shared.close(webContentId: paneId, removeIfPinned: false)
        }
        var result = "Closed \(tabIds.count - unknown.count) tabs."
        if !unknown.isEmpty {
            result += " Unknown tab ids: \(unknown.joined(separator: ", "))."
        }
        return result
    }

    @MainActor
    private func openURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), url.scheme != nil else {
            return "Error: invalid URL '\(urlString)'."
        }
        guard let windowID = targetWindowID() else {
            return "Error: no browser window is open."
        }
        BrowserStore.shared.modify { state in
            state.openTab(url: url, activate: false, windowID: windowID)
        }
        return "Opened \(url.absoluteString) in a new background tab."
    }

    @MainActor
    private func showToUser(message: String) -> String {
        guard let session else { return "Error: session is gone." }
        BrowserStore.shared.modify { state in
            state.modifyTab(id: session.tabID) { tab in
                tab.agentInfo?.statusText = message
            }
        }
        session.revealTab()
        return "Your tab is now visible to the user. They can read your messages there."
    }
}
