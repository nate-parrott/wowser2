import Foundation

// BrowserJSLiveHost's implementation of the chat-mode surface:
// `browser.present`, `browser.agents.*`, `browser.terminal.*`.
//
// Every call carries the calling agent's session key (nil for the MCP
// runtime); ChatAgentRegistry turns that into "whose thread gets the card,
// which tab is the caller's own, which window to act in".

extension BrowserJSLiveHost {

    // MARK: - present

    public func chatPresent(agentKey: String?, tabId: String?, url: String?, show: String, note: String?) async throws -> String {
        try await Task { @MainActor in
            let ctx = ChatAgentRegistry.callerContext(agentKey: agentKey)
            let paneID: ID<WebContent>
            if let tabId {
                paneID = ID<WebContent>(raw: tabId)
                guard BrowserStore.shared.model.paneToTabMapping[paneID] != nil else { throw BrowserJSError.tabNotFound(tabId) }
            } else if let url, let parsed = URL(string: url) {
                paneID = try Self.openBackgroundTab(url: parsed, ctx: ctx)
            } else {
                throw BrowserJSError.invalidArgs("pass tabId or url")
            }
            try await Self.presentPane(paneID, show: show, note: note, ctx: ctx)
            return paneID.raw
        }.value
    }

    /// Open `url` as a visible-but-background tab in the caller's window and
    /// start loading it.
    @MainActor
    fileprivate static func openBackgroundTab(url: URL, ctx: ChatAgentRegistry.CallerContext) throws -> ID<WebContent> {
        guard let winID = ctx.windowID ?? BrowserStore.shared.model.windowsMostRecentFirst.first?.id else {
            throw BrowserJSError.windowNotFound("current")
        }
        let pid = ID<WebContent>.assign()
        BrowserStore.shared.modify { st in
            var tab = Tab(id: .assign(), panes: [Pane(id: pid, info: .init(url: url))])
            tab.lastActiveInWindow = winID
            let loc = st.insertionIndex(window: winID, spawningTabId: st.windows[winID]?.currentTab)
            st.insertTab(tab, location: loc, inWindow: winID)
        }
        _ = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
        return pid
    }

    /// Card and/or main-view presentation of an existing pane.
    @MainActor
    fileprivate static func presentPane(_ paneID: ID<WebContent>, show: String, note: String?, ctx: ChatAgentRegistry.CallerContext) async throws {
        let state = BrowserStore.shared.model
        guard let tabID = state.paneToTabMapping[paneID] else { throw BrowserJSError.tabNotFound(paneID.raw) }
        let winID = state.windowContaining(tabId: tabID)?.id ?? ctx.windowID
        let wantsCard = show == "card" || show == "both"
        let wantsMain = show == "main" || show == "both"

        if wantsCard {
            await addCard(paneID: paneID, tabID: tabID, note: note, ctx: ctx)
        }
        if wantsMain, let winID {
            BrowserStore.shared.modify { st in
                // A subagent showing a page while the user is looking at the
                // subagent's own tab: open beside it as a split and collapse
                // the sidebar so both fit.
                if let own = ctx.ownPaneID, let ownTab = st.paneToTabMapping[own],
                   st.windows[winID]?.currentTab == ownTab, ownTab != tabID {
                    st.unghostTab(id: tabID)
                    st.moveAllPanesToSplitView(sourceTabId: tabID, destinationTabId: ownTab, activateLast: true)
                    st.windows[winID]?.sidebarLocked = false
                } else {
                    st.activate(tabId: tabID, in: winID)
                    st.unghostTab(id: tabID)
                    if let idx = st.tabs[tabID]?.panes.asArray.firstIndex(where: { $0.id == paneID }) {
                        st.modifyTab(id: tabID) { $0.focusedPaneIdx = idx }
                    }
                }
            }
        }
    }

    /// Drop a card for `tabID` into the caller's thread: the space thread for
    /// a coordinator (or outside caller), the agent's own transcript for a
    /// subagent / agent tab.
    @MainActor
    fileprivate static func addCard(paneID: ID<WebContent>, tabID: ID<Tab>, note: String?, ctx: ChatAgentRegistry.CallerContext) async {
        if let key = ctx.key, ChatAgentRegistry.profileID(forCoordinatorKey: key) == nil {
            // Subagent / agent tab: card in its own transcript.
            if let id = await BrowserAgentManager.shared.agentID(forKey: key) {
                let url = BrowserStore.shared.model.tabs[tabID]?.focusedPane?.info.url?.absoluteString
                try? await BrowserAgentManager.shared.appendLocalMessage(id: id, role: "tab_card", text: paneID.raw, toolName: note ?? url)
            }
            // …and, if its space is in chat mode, the coordinator's thread too
            // (that's what the user is looking at in the sidebar).
            if let pid = ctx.threadProfileID {
                ChatSpaceSession.session(for: pid).addCard(tabID: tabID, note: note, force: true)
            }
            return
        }
        if let pid = ctx.threadProfileID {
            ChatSpaceSession.session(for: pid).addCard(tabID: tabID, note: note, force: true)
        }
    }

    // MARK: - agents

    public func agentsSpawn(agentKey: String?, task: String, name: String?, model: String?, effort: String?, fileSystemTools: Bool, workingDirectory: String?, show: String) async throws -> BrowserJSSpawnedAgentInfo {
        try await Task { @MainActor in
            let ctx = ChatAgentRegistry.callerContext(agentKey: agentKey)
            guard let winID = ctx.windowID ?? BrowserStore.shared.model.windowsMostRecentFirst.first?.id else {
                throw BrowserJSError.windowNotFound("current")
            }
            let parentKey = agentKey ?? ctx.threadProfileID.map { ChatAgentRegistry.coordinatorKey(for: $0) } ?? "mcp"
            let state = BrowserStore.shared.model
            let folder = ctx.threadProfileID.flatMap { state.profiles[$0]?.folderPath }
            let spec = AgentChatSession.SubagentSpec(
                parentKey: parentKey,
                name: name?.nilIfEmpty ?? String(task.prefix(40)),
                model: model,
                effort: effort,
                fileSystemTools: fileSystemTools,
                workingDirectory: workingDirectory ?? (fileSystemTools ? folder : nil)
            )
            let wantsMain = show == "main" || show == "both"
            let (key, paneID) = AgentChatTabs.spawnSubagent(task: task, spec: spec, windowID: winID, background: !wantsMain, ghost: show == "none")
            if show != "none" {
                try await Self.presentPane(paneID, show: show, note: nil, ctx: ctx)
            }
            return BrowserJSSpawnedAgentInfo(key: key, tabId: paneID.raw, url: NativePageKey.agent(key: key, query: spec.name).url.absoluteString)
        }.value
    }

    public func agentsSend(agentKey: String?, toKey: String, text: String) async throws {
        // Coordinators are created lazily by their space session; make sure
        // the target exists before resolving.
        let targetID: String? = await Task { @MainActor () -> String? in
            if let pid = ChatAgentRegistry.profileID(forCoordinatorKey: toKey) {
                return await ChatSpaceSession.session(for: pid).ensureAgent()
            }
            return await BrowserAgentManager.shared.agentID(forKey: toKey)
        }.value
        guard let targetID else { throw BrowserJSError.invalidArgs("no agent with key \(toKey)") }
        let senderName: String = await MainActor.run {
            if let agentKey { return ChatAgentRegistry.displayName(forKey: agentKey) }
            return "an outside agent"
        }
        let fromKey = agentKey ?? "mcp"
        if let agentKey, let parent = await MainActor.run(body: { ChatAgentRegistry.record(forKey: agentKey)?.parentKey }), parent == toKey {
            await MainActor.run { ChatAgentRegistry.markReportedToParent(key: agentKey) }
        }
        try await BrowserAgentManager.shared.send(
            id: targetID,
            text: "[Message from agent \"\(senderName)\" (key \(fromKey)) — not from the user]\n\(text)",
            images: [],
            displayText: text,
            role: "peer",
            label: senderName
        )
    }

    public func agentsList(agentKey: String?) async throws -> [BrowserJSPeerAgentInfo] {
        let infos = await BrowserAgentManager.shared.list()
        return await MainActor.run {
            let state = BrowserStore.shared.model
            func status(_ key: String) -> String { infos.first(where: { $0.key == key })?.status ?? "saved" }
            @MainActor func entry(_ key: String, name: String?, parent: String?, isSelf: Bool) -> BrowserJSPeerAgentInfo {
                let pane = state.agentChatPane(forKey: key)
                return BrowserJSPeerAgentInfo(
                    key: key, name: name ?? ChatAgentRegistry.displayName(forKey: key), status: status(key),
                    tabId: pane?.raw, url: pane.flatMap { state.pane(forId: $0)?.info.url?.absoluteString },
                    parentKey: parent, isSelf: isSelf
                )
            }
            var out: [BrowserJSPeerAgentInfo] = []
            let ctx = ChatAgentRegistry.callerContext(agentKey: agentKey)
            let selfKey = agentKey ?? ctx.threadProfileID.map { ChatAgentRegistry.coordinatorKey(for: $0) }
            if let selfKey {
                out.append(entry(selfKey, name: ChatAgentRegistry.record(forKey: selfKey)?.name, parent: ChatAgentRegistry.record(forKey: selfKey)?.parentKey, isSelf: true))
                if let parent = ChatAgentRegistry.record(forKey: selfKey)?.parentKey {
                    out.append(entry(parent, name: nil, parent: ChatAgentRegistry.record(forKey: parent)?.parentKey, isSelf: false))
                }
                for child in ChatAgentRegistry.children(of: selfKey) {
                    out.append(entry(child.key, name: child.name, parent: selfKey, isSelf: false))
                }
            }
            return out
        }
    }

    public func agentsTranscript(key: String, since: Int) async throws -> [BrowserJSAgentMessage] {
        guard let id = await BrowserAgentManager.shared.agentID(forKey: key) else {
            throw BrowserJSError.invalidArgs("no agent with key \(key)")
        }
        return try await BrowserAgentManager.shared.messages(id: id, since: since)
    }

    // MARK: - terminal

    public func terminalOpen(agentKey: String?, cwd: String?, command: String?, show: String) async throws -> String {
        #if os(macOS)
        return try await Task { @MainActor in
            let ctx = ChatAgentRegistry.callerContext(agentKey: agentKey)
            let state = BrowserStore.shared.model
            guard let winID = ctx.windowID ?? state.windowsMostRecentFirst.first?.id else {
                throw BrowserJSError.windowNotFound("current")
            }
            let folder = cwd?.nilIfEmpty
                ?? ctx.threadProfileID.flatMap { state.profiles[$0]?.folderPath?.nilIfEmpty }
                ?? state.mostRecentNativeFolderPath(windowID: winID)
            let key = NativePageKey.terminal(cwd: folder, runCommand: command?.nilIfEmpty)
            let pid = ID<WebContent>.assign()
            BrowserStore.shared.modify { st in
                var pane = Pane(id: pid, info: .init(url: key.url))
                pane.isGhost = show == "none"
                var tab = Tab(id: .assign(), panes: [pane])
                tab.lastActiveInWindow = winID
                let loc = st.insertionIndex(window: winID, spawningTabId: st.windows[winID]?.currentTab)
                st.insertTab(tab, location: loc, inWindow: winID)
            }
            guard let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID) else {
                throw BrowserJSError.tabNotFound(pid.raw)
            }
            // Start the shell now, even though no overlay is showing it.
            let session = TerminalSession.ensure(for: wc)
            session.start(cwd: folder, runCommand: command?.nilIfEmpty, paneID: pid)
            if show != "none" {
                try await Self.presentPane(pid, show: show, note: nil, ctx: ctx)
            }
            return pid.raw
        }.value
        #else
        throw BrowserJSError.notImplemented("terminal.open (macOS only)")
        #endif
    }

    public func terminalRead(id: String, since: String?, maxChars: Int?) async throws -> BrowserJSTerminalRead {
        #if os(macOS)
        return try await Task { @MainActor in
            let session = try Self.terminalSession(forID: id)
            let (text, token) = session.read(since: since, maxChars: maxChars ?? 20_000)
            return BrowserJSTerminalRead(text: text, token: token, running: !session.shellIsAtPrompt, command: session.foregroundCommandForAgents, cwd: session.lastKnownCwd)
        }.value
        #else
        throw BrowserJSError.notImplemented("terminal.read (macOS only)")
        #endif
    }

    public func terminalWrite(id: String, text: String) async throws {
        #if os(macOS)
        try await Task { @MainActor in
            let session = try Self.terminalSession(forID: id)
            session.write(text)
        }.value
        #else
        throw BrowserJSError.notImplemented("terminal.write (macOS only)")
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func terminalSession(forID id: String) throws -> TerminalSession {
        let pid = ID<WebContent>(raw: id)
        let state = BrowserStore.shared.model
        guard let pane = state.pane(forId: pid), let url = pane.info.url, NativePageKey(url: url)?.isTerminal == true,
              let winID = state.windowContaining(webContentId: pid)?.id,
              let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
        else { throw BrowserJSError.invalidArgs("\(id) is not a terminal tab") }
        let session = TerminalSession.ensure(for: wc)
        session.startIfNeededFromURL()
        return session
    }
    #endif
}
