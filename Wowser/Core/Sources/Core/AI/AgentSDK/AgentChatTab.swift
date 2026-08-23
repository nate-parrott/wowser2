import Foundation
import SwiftUI

// "Ask agent" tabs: a native chat tab backed by BrowserAgentManager.
//
// Spin-up (from the omnibox): we open the agent tab *attached to the omnibox*
// — hidden from the sidebar, surfaced as a working indicator in the address
// bar (see BrowserState+AttachedAgents) — capture what the user was looking
// at (URL, selection, viewport text) into the agent's system prompt, and send
// the query. The agent itself decides how to deliver: it can focus its own
// tab via `browser.tabs.activate(...)` (which restores it to the sidebar) and
// answer in chat, or perform a navigation and dismiss itself with the `done`
// tool. If it ends its turn while still hidden, we pop the tab if it wrote
// anything worth reading and close it otherwise.
//
// Scheduled tasks (see ScheduledTasks.swift) reuse the same machinery in
// `.scheduledTask` mode: headless by default, surfacing only on error or
// when the agent deliberately activates itself.

@MainActor
public enum AgentChatTabs {
    nonisolated static let keyPrefix = "agenttab-"

    private static var didInstallTools = false
    static func installToolsIfNeeded() {
        guard !didInstallTools else { return }
        didInstallTools = true
        Task {
            await BrowserAgentManager.shared.setNativeToolProvider { key in
                guard key.hasPrefix(keyPrefix) else { return [] }
                return [makeDoneTool(key: key)]
            }
        }
    }

    /// Entry point from the omnibox "Ask Agent" result. Opens the tab in the
    /// background and kicks off the agent.
    public static func ask(query: String, windowID: ID<WindowState>, dictated: Bool = false) {
        installToolsIfNeeded()
        let key = keyPrefix + String(UUID().uuidString.lowercased().prefix(8))

        // What was the user looking at when they asked? Capture the pane
        // BEFORE we insert the agent tab.
        let currentPane = BrowserStore.shared.model.currentPane(forWindow: windowID)
        let url = NativePageKey.agent(key: key, query: query).url

        var paneID: ID<WebContent>!
        var sourcePaneID: ID<WebContent>?
        var reusedCurrentTab = false
        if let currentPane, currentPane.info.isEmptyPage {
            // The user asked from a new-tab page — take over that tab instead
            // of spawning another one. It's already focused.
            paneID = currentPane.id
            reusedCurrentTab = true
            BrowserStore.shared.modify { st in
                st.modifyPaneAndTab(forWebContentId: currentPane.id) { pane, _ in
                    var info = WebContent.Info(url: url)
                    info.agentIsWorking = true
                    pane.info = info
                }
            }
            if let webContent = BrowserStore.shared.getOrCreateWebContent(forId: currentPane.id, toBeActiveInWindow: windowID) {
                webContent.load(url: url)
            }
        } else {
            sourcePaneID = currentPane?.id
            paneID = insertAttachedTab(key: key, url: url, windowID: windowID)
        }

        let session = AgentChatSession.session(forKey: key)
        session.begin(
            query: query,
            ownPaneID: paneID,
            sourcePaneID: sourcePaneID,
            ownTabIsFocused: reusedCurrentTab,
            mode: .ask(dictated: dictated)
        )
    }

    /// Runs a scheduled task: a headless agent attached to the window's omnibox.
    /// It surfaces only if it activates itself (to show something) or errors.
    /// `completion` receives the agent's final text (or error) when the turn ends.
    public static func runScheduledTask(_ task: ScheduledTask, windowID: ID<WindowState>, completion: @escaping (_ result: ScheduledTaskRunResult) -> Void) {
        installToolsIfNeeded()
        let key = keyPrefix + "task-" + String(UUID().uuidString.lowercased().prefix(8))
        let url = NativePageKey.agent(key: key, query: task.title).url
        let paneID = insertAttachedTab(key: key, url: url, windowID: windowID)
        let session = AgentChatSession.session(forKey: key)
        session.onScheduledTaskFinished = completion
        session.begin(
            query: task.instructions,
            ownPaneID: paneID,
            sourcePaneID: nil,
            ownTabIsFocused: false,
            mode: .scheduledTask
        )
    }

    /// Creates a working agent tab hidden behind the omnibox of `windowID`.
    private static func insertAttachedTab(key: String, url: URL, windowID: ID<WindowState>) -> ID<WebContent> {
        let pid = ID<WebContent>.assign()
        BrowserStore.shared.modify { st in
            var info = WebContent.Info(url: url)
            info.agentIsWorking = true
            let tab = Tab(id: .assign(), panes: [Pane(id: pid, info: info)])
            st.attachAgentTab(tab, toWindow: windowID)
        }
        // Materialize the WebContent so the chat overlay session can mount
        // later without a cold start, and so the pane survives the cleaner.
        if let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: windowID) {
            wc.info.agentIsWorking = true
        }
        return pid
    }

    /// Bring a hidden agent tab forward (the user clicked the omnibox
    /// indicator). Restores it to the sidebar and activates it.
    public static func reveal(tabID: ID<Tab>, windowID: ID<WindowState>) {
        BrowserStore.shared.modify { st in
            st.activate(tabId: tabID, in: windowID)
        }
    }

    /// Open a fresh, empty chat tab (from the "New Chat" command / plus menu).
    /// Activated immediately — the user asked for it; the agent is created
    /// lazily when the overlay mounts.
    public static func newChat(windowID: ID<WindowState>?) {
        installToolsIfNeeded()
        let key = keyPrefix + String(UUID().uuidString.lowercased().prefix(8))
        BrowserStore.shared.modify { st in
            st.openTab(url: NativePageKey.agent(key: key, query: nil).url, activate: true, windowID: windowID)
        }
    }

    /// Open a link the user clicked inside an agent chat: navigate the chat
    /// tab's existing split pane if it has one, otherwise open the link in a
    /// new split beside the chat. Keyboard focus stays on the chat.
    public static func openLink(_ url: URL, fromAgentPane paneID: ID<WebContent>) {
        let state = BrowserStore.shared.model
        guard let tabID = state.paneToTabMapping[paneID],
              let tab = state.tabs[tabID],
              let winID = state.windowContaining(tabId: tabID)?.id
        else {
            BrowserStore.shared.modify { st in st.openTab(url: url) }
            return
        }
        if let other = tab.panes.first(where: { $0.id != paneID }) {
            BrowserStore.shared.modify { st in
                st.modifyPaneAndTab(forWebContentId: other.id) { pane, _ in
                    pane.info = WebContent.Info(url: url)
                }
            }
            if let webContent = BrowserStore.shared.getOrCreateWebContent(forId: other.id, toBeActiveInWindow: winID) {
                webContent.load(url: url)
            }
        } else {
            BrowserStore.shared.modify { st in
                st.modifyTab(id: tabID) { t in
                    t.panes.append(Pane(id: .assign(), info: .init(url: url)))
                }
            }
        }
    }

    /// Close the agent's tab and shut its session down. Called by the `done`
    /// tool and when the user dismisses the chat.
    public static func close(key: String) {
        let paneID = BrowserStore.shared.model.agentChatPane(forKey: key)
        if let paneID {
            BrowserStore.shared.close(webContentId: paneID, removeIfPinned: false)
        }
        AgentChatSession.remove(forKey: key)
        Task {
            let infos = await BrowserAgentManager.shared.list()
            if let info = infos.first(where: { $0.key == key }) {
                try? await BrowserAgentManager.shared.dispose(id: info.id)
            }
        }
    }

    private nonisolated static func makeDoneTool(key: String) -> AgentToolDefinition {
        AgentToolDefinition(
            name: "done",
            description: """
            Finish this task and dismiss yourself: closes your chat tab and ends \
            the session. Call this ONLY when you have delivered the result some \
            other way (e.g. opened a page for the user) and there is nothing for \
            the user to read in this chat. Never call it after answering in chat.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"reason":{"type":"string","description":"One short line on how the task was delivered."}},"required":[]}"#
        ) { _ in
            Task { @MainActor in
                // Give the harness a beat to finish the turn cleanly.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                AgentChatTabs.close(key: key)
            }
            return AgentToolOutput(text: "Task complete — your tab will close.", isError: false)
        }
    }
}

extension BrowserState {
    /// The pane hosting the agent chat tab with this session key, if open.
    public func agentChatPane(forKey key: String) -> ID<WebContent>? {
        for tab in tabs.values {
            for pane in tab.panes {
                if let url = pane.info.url, NativePageKey(url: url)?.agentKey == key {
                    return pane.id
                }
            }
        }
        return nil
    }
}

// MARK: - Chat session (view model)

/// Runtime state for one agent chat tab: transcript, working flag, and the
/// scroll position — kept in a static registry so it survives view remounts,
/// tab switches, and WebContent eviction. One per session key.
@MainActor
public final class AgentChatSession: ObservableObject {
    private static var sessions: [String: AgentChatSession] = [:]

    public static func session(forKey key: String) -> AgentChatSession {
        if let existing = sessions[key] { return existing }
        let session = AgentChatSession(key: key)
        sessions[key] = session
        return session
    }

    static func remove(forKey key: String) {
        sessions[key]?.turnLoopTask?.cancel()
        sessions[key] = nil
    }

    public enum Mode: Equatable {
        /// A question typed (or dictated) into the omnibox.
        case ask(dictated: Bool)
        /// A follow-up "New Chat" tab the user opened deliberately.
        case chat
        /// A background run of a scheduled task.
        case scheduledTask
    }

    public let key: String
    public private(set) var mode: Mode = .chat
    @Published public private(set) var messages: [BrowserJSAgentMessage] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorText: String?
    /// Scheduled-task mode only: called once when the first turn ends.
    var onScheduledTaskFinished: ((ScheduledTaskRunResult) -> Void)?

    /// Scroll offset of the transcript, preserved across view remounts.
    public var savedScrollY: CGFloat?

    private var agentID: String?
    private var ownPaneID: ID<WebContent>?
    private var nextIndex = 0
    private var turnLoopTask: Task<Void, Never>?
    private var didBegin = false
    private var turnsCompleted = 0

    private init(key: String) {
        self.key = key
    }

    /// Spin up a fresh agent for a new "ask" — context capture, create, send.
    func begin(query: String, ownPaneID: ID<WebContent>, sourcePaneID: ID<WebContent>?, ownTabIsFocused: Bool, mode: Mode) {
        guard !didBegin else { return }
        didBegin = true
        self.mode = mode
        self.ownPaneID = ownPaneID
        setWorking(true)
        Task {
            let context = mode == .scheduledTask ? nil : await AgentChatSession.capturePageContext(paneID: sourcePaneID)
            do {
                let prompt: String
                switch mode {
                case .scheduledTask:
                    prompt = AgentChatSession.scheduledTaskSystemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: query).url.absoluteString
                    )
                case .ask(let dictated):
                    prompt = AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: query).url.absoluteString,
                        sourcePaneID: sourcePaneID,
                        ownTabIsFocused: ownTabIsFocused,
                        pageContext: context,
                        dictated: dictated
                    )
                case .chat:
                    prompt = AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: query).url.absoluteString,
                        sourcePaneID: sourcePaneID,
                        ownTabIsFocused: ownTabIsFocused,
                        pageContext: context,
                        dictated: false
                    )
                }
                let options = BrowserJSAgentCreateOptions(
                    key: key,
                    name: mode == .scheduledTask ? "Task: " + String(query.prefix(60)) : query,
                    effort: mode == .scheduledTask ? "medium" : "low",
                    systemPrompt: prompt
                )
                let id = try await BrowserAgentManager.shared.create(options: options)
                self.agentID = id
                try await BrowserAgentManager.shared.send(id: id, text: query, images: [])
                self.runTurnLoop()
            } catch {
                self.errorText = error.localizedDescription
                self.setWorking(false)
            }
        }
    }

    /// Attach to an existing or brand-new session (a "New Chat" tab, or the
    /// overlay mounting for a tab that survived an app restart). Resumes the
    /// keyed agent if it has a saved record — its stored system prompt wins —
    /// otherwise creates it fresh with a generic prompt naming its own tab.
    func attachIfNeeded(ownPaneID: ID<WebContent>) {
        guard !didBegin else { return }
        didBegin = true
        self.ownPaneID = ownPaneID
        AgentChatTabs.installToolsIfNeeded()
        Task {
            do {
                let options = BrowserJSAgentCreateOptions(
                    key: key,
                    effort: "low",
                    systemPrompt: AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: nil).url.absoluteString,
                        sourcePaneID: nil,
                        ownTabIsFocused: true,
                        pageContext: nil,
                        dictated: false
                    )
                )
                let id = try await BrowserAgentManager.shared.create(options: options)
                self.agentID = id
                let existing = (try? await BrowserAgentManager.shared.messages(id: id, since: 0)) ?? []
                self.mergeMessages(existing)
                self.runTurnLoop()
            } catch {
                self.errorText = error.localizedDescription
            }
        }
    }

    /// Send a follow-up message typed in the chat.
    public func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let agentID else { return }
        errorText = nil
        setWorking(true)
        Task {
            do {
                try await BrowserAgentManager.shared.send(id: agentID, text: trimmed, images: [])
                self.runTurnLoop()
            } catch {
                self.errorText = error.localizedDescription
                self.setWorking(false)
            }
        }
    }

    public func interrupt() {
        guard let agentID else { return }
        Task { try? await BrowserAgentManager.shared.interrupt(id: agentID) }
    }

    // MARK: - Internals

    /// Long-polls the manager while a turn runs, streaming transcript entries
    /// into `messages` as they land. Ends when the agent goes idle.
    private func runTurnLoop() {
        guard turnLoopTask == nil else { return }
        turnLoopTask = Task { [weak self] in
            defer { Task { @MainActor in self?.turnLoopTask = nil } }
            while !Task.isCancelled {
                guard let self, let id = self.agentID else { return }
                guard let res = try? await BrowserAgentManager.shared.awaitIdle(id: id, timeoutMs: 30_000, since: self.nextIndex) else {
                    self.setWorking(false)
                    return
                }
                self.mergeMessages(res.messages)
                if res.done {
                    self.setWorking(false)
                    if res.isError, let text = res.text { self.errorText = text }
                    self.turnsCompleted += 1
                    self.turnDidEnd(result: res)
                    return
                }
            }
        }
    }

    /// A turn finished. For a hidden (omnibox-attached) agent that neither
    /// focused itself nor called `done`, decide for it: surface the tab if
    /// there's something to read, otherwise clean up.
    private func turnDidEnd(result: BrowserJSAgentAwaitResult) {
        guard let ownPaneID else { return }
        let state = BrowserStore.shared.model
        guard let tabID = state.paneToTabMapping[ownPaneID],
              let winID = state.windowContaining(tabId: tabID)?.id else {
            if mode == .scheduledTask { finishScheduledTask(result: result) }
            return
        }
        let stillAttached = state.isAttachedAgentTab(tabID)

        switch mode {
        case .scheduledTask:
            // Headless run. If the agent did not reveal itself and nothing
            // went wrong, close the tab and dispose the session; otherwise
            // pop it into the sidebar so the user can see what happened.
            finishScheduledTask(result: result)
            if stillAttached {
                if result.isError || errorText != nil {
                    BrowserStore.shared.modify { st in st.detachAgentTab(tabID: tabID, inWindow: winID) }
                } else {
                    AgentChatTabs.close(key: key)
                }
            }
        case .ask, .chat:
            guard stillAttached, turnsCompleted == 1 else { return }
            let hasAnswer = messages.contains { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if hasAnswer || result.isError || errorText != nil {
                // Pop up as a real tab: the agent wrote something for the user.
                AgentChatTabs.reveal(tabID: tabID, windowID: winID)
            } else {
                // Nothing to read; treat like `done`.
                AgentChatTabs.close(key: key)
            }
        }
    }

    private func finishScheduledTask(result: BrowserJSAgentAwaitResult) {
        guard let onScheduledTaskFinished else { return }
        self.onScheduledTaskFinished = nil
        let lastAssistant = messages.last(where: { $0.role == "assistant" })?.text
        let summary = (result.text?.nilIfEmpty ?? lastAssistant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onScheduledTaskFinished(ScheduledTaskRunResult(
            finishedAt: Date(),
            summary: String(summary.prefix(500)),
            isError: result.isError || errorText != nil
        ))
    }

    private func mergeMessages(_ new: [BrowserJSAgentMessage]) {
        guard !new.isEmpty else { return }
        let known = Set(messages.map(\.index))
        messages.append(contentsOf: new.filter { !known.contains($0.index) })
        messages.sort { $0.index < $1.index }
        nextIndex = (messages.last?.index ?? -1) + 1
        statusDetail = AgentChatSession.statusDetail(for: messages.last)
        writeTabStatus()
    }

    private var statusDetail: String?

    private static func statusDetail(for message: BrowserJSAgentMessage?) -> String? {
        guard let message else { return nil }
        switch message.role {
        case "thinking": return "Thinking…"
        case "assistant": return "Writing…"
        case "tool_use":
            switch message.toolName {
            case "run_browser_js": return "Driving the browser…"
            case "done": return "Wrapping up…"
            case .some(let name): return "Using \(name)…"
            case nil: return "Using a tool…"
            }
        default: return "Working…"
        }
    }

    private func setWorking(_ working: Bool) {
        if isWorking != working { isWorking = working }
        if !working { statusDetail = nil }
        writeTabStatus()
    }

    private func writeTabStatus() {
        let key = self.key
        let working = isWorking
        let detail = statusDetail
        guard let pid = BrowserStore.shared.model.agentChatPane(forKey: key) else { return }
        // The live WebContent's `info` is the source of truth: every metadata
        // refresh copies it wholesale into the pane, so writing only to the
        // pane gets wiped on the next refresh. Write to the WebContent when it
        // exists (it propagates to state via infoDidChange), else to state.
        if let wc = BrowserStore.shared.existingWebContent(forId: pid) {
            var info = wc.info
            if info.agentIsWorking != working { info.agentIsWorking = working }
            if info.agentStatusDetail != detail { info.agentStatusDetail = detail }
            if info != wc.info { wc.info = info }
        }
        BrowserStore.shared.modify { st in
            st.modifyPaneAndTab(forWebContentId: pid) { pane, _ in
                if pane.info.agentIsWorking != working { pane.info.agentIsWorking = working }
                if pane.info.agentStatusDetail != detail { pane.info.agentStatusDetail = detail }
            }
        }
    }

    // MARK: - Context capture + prompt

    /// One-shot JS grab of what the user is looking at: URL, title, selection,
    /// and the text currently visible in the viewport.
    private static func capturePageContext(paneID: ID<WebContent>?) async -> String? {
        guard let paneID else { return nil }
        // Skip native/empty panes — nothing meaningful to read.
        if let url = BrowserStore.shared.model.pane(forId: paneID)?.info.url,
           NativePageKey(url: url) != nil || url.absoluteString.hasPrefix("about:") {
            return nil
        }
        let js = """
        (() => {
            const sel = window.getSelection ? String(window.getSelection()) : '';
            const vh = window.innerHeight, vw = window.innerWidth;
            const parts = [];
            let total = 0;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                const t = node.textContent.trim();
                if (!t) continue;
                const el = node.parentElement;
                if (!el) continue;
                const tag = el.tagName;
                if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
                const r = el.getBoundingClientRect();
                if (r.width === 0 || r.height === 0) continue;
                if (r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) continue;
                parts.push(t);
                total += t.length;
                if (total > 12000) break;
            }
            return {
                url: location.href,
                title: document.title,
                selection: sel.slice(0, 2000),
                viewportText: parts.join('\\n').slice(0, 12000)
            };
        })()
        """
        guard let result = try? await BrowserJSLiveHost.shared.pageEval(id: paneID.raw, js: js),
              let dict = result as? [String: Any] else { return nil }
        let url = dict["url"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let selection = (dict["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let viewportText = dict["viewportText"] as? String ?? ""
        var out = """
        ## What the user is looking at

        The user asked from a tab (tab id "\(paneID.raw)") showing:
        URL: \(url)
        Title: \(title)
        """
        if !selection.isEmpty {
            out += "\n\nThey have this text SELECTED (likely what \"this\" refers to):\n\"\"\"\n\(selection)\n\"\"\""
        } else {
            out += "\n\nNo text is selected."
        }
        if !viewportText.isEmpty {
            out += "\n\nText currently visible in their viewport:\n\"\"\"\n\(viewportText)\n\"\"\""
        }
        return out
    }

    private static func systemPrompt(ownPaneID: ID<WebContent>, agentURL: String, sourcePaneID: ID<WebContent>?, ownTabIsFocused: Bool, pageContext: String?, dictated: Bool) -> String {
        let own = ownPaneID.raw
        var prompt = """
        You are a quick, helpful in-browser agent inside the Wowser browser. The \
        user asked you something from the address bar. Your chat lives in its own \
        tab — tab id "\(own)", url "\(agentURL)" — \
        \(ownTabIsFocused
            ? "which the user is already looking at."
            : "which is currently HIDDEN: not in the sidebar and not focused — the address bar just shows that you are working. Activating it (see below) reveals it.")

        FIRST choose the right presentation for your response, then act:

        """
        if dictated {
            prompt += """
            NOTE: the user's message was DICTATED via speech recognition, so it may \
            contain transcription errors, missing punctuation, homophones, or filler \
            words. Interpret what they most plausibly meant rather than reading it \
            literally, and don't comment on the transcription quality.

            """
        }
        if let src = sourcePaneID?.raw {
            prompt += """
            1. CHAT ANSWER about the page the user is on (summarize / explain \
            "this" / questions about what they're reading): show this chat in a \
            SPLIT beside their page so they can see both. Call `run_browser_js`:
               await browser.tabs.openSplit("\(agentURL)", { besideTabId: "\(src)", activate: true });
               await browser.tabs.close("\(own)");
               (The split pane shows this same chat.) Then write your answer \
            here. Do NOT call `done`.

            2. CHAT ANSWER not tied to their current page: focus your own tab \
            with `run_browser_js`:
               await browser.tabs.activate("\(own)")
               Then answer. Do NOT call `done`.

            3. NAVIGATION — the user wants a page or place opened ("show me \
            directions to X", "open Y", "take me to ..."): do NOT focus your \
            chat. If the destination complements the page they're on, open it \
            in a split beside it:
               await browser.tabs.openSplit(url, { besideTabId: "\(src)", activate: true })
               Otherwise open it as a full tab: await browser.tabs.open(url)
               Then call the `done` tool so your chat tab dismisses itself.
            """
        } else {
            prompt += """
            1. CHAT ANSWER (explain / summarize / compare / questions): \
            \(ownTabIsFocused
                ? "your tab is already focused — just write the answer here."
                : """
                FIRST focus your own tab with `run_browser_js`:
                   await browser.tabs.activate("\(own)")
                   Then write the answer here.
                """) Do NOT call `done`.

            2. NAVIGATION — the user wants a page or place opened ("show me \
            directions to X", "open Y"): open the destination as a full tab with \
            `run_browser_js` (e.g. `await browser.tabs.open("https://www.google.com/maps/dir/?api=1&destination=...")`), \
            then call the `done` tool so your chat tab dismisses itself.
            """
        }
        prompt += """


        ## Web research

        For anything that needs the live web (recommendations, "find X", \
        comparisons, current info), run the research as a split the user can \
        watch: your chat on one side, the page you're currently reading on the \
        other.

        1. First make your chat visible (case 1 or 2 above).
        2. Open your first search as a split beside your chat, WITHOUT stealing \
        focus, and keep the returned pane id:
           const research = await browser.tabs.openSplit(searchURL, { besideTabId: "\(own)", activate: false });
        3. Reuse that ONE pane for every later search and article:
           await browser.tabs.navigate(research, url);
           Never stack more panes or open extra tabs while researching — the \
        single research pane always shows what you're reading now, so the user \
        can follow along.
        4. Read pages with `await browser.content.read(research, { as: "markdown" })`; \
        use `browser.viewImage(await browser.content.screenshot(research))` \
        only when layout/visuals matter.
        5. Bring the user along: drop short interim notes in chat as you learn \
        things, and write findings as markdown links — e.g. \
        `[Café de Klos](https://...)`. When the user clicks a link in your \
        chat, it opens in the research pane automatically — so always link \
        the places, articles, and sources you mention.
        6. Do NOT call `done` after research — your findings in chat ARE the \
        deliverable.

        Be concise and direct — this is a small chat pane, not a document. Use \
        the page context below when the user says "this". Only reach for other \
        browser tools when they actually help.
        """
        if let pageContext {
            prompt += "\n\n" + pageContext
        }
        return prompt
    }

    private static func scheduledTaskSystemPrompt(ownPaneID: ID<WebContent>, agentURL: String) -> String {
        """
        You are a background maintenance agent inside the Wowser browser, running \
        a SCHEDULED TASK the user set up earlier. The user is not watching and did \
        not just ask for this — work silently and headlessly.

        Your chat lives in a hidden tab — tab id "\(ownPaneID.raw)", url "\(agentURL)" \
        — that is NOT shown in the sidebar. The address bar just shows that you \
        are working. Use `run_browser_js` to read and modify the browser (tabs, \
        spaces, history, …) and do the task. Do not open new tabs for the user \
        unless the task requires it, and never steal focus for routine work.

        Only if you genuinely need the user to see something — you hit an error \
        you cannot resolve, or the task asked you to present a result — reveal \
        your tab with `await browser.tabs.activate("\(ownPaneID.raw)")` and \
        write it in chat. Otherwise, when the task is complete, write a one- or \
        two-sentence summary of what you did as your final message (this is \
        recorded as the run's status) and stop. Do NOT call `done`; the browser \
        closes your tab automatically.
        """
    }
}

/// What a scheduled task run reported back when its agent turn ended.
public struct ScheduledTaskRunResult: Equatable {
    public var finishedAt: Date
    public var summary: String
    public var isError: Bool
}
