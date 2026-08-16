import Foundation
import SwiftUI

// "Ask agent" tabs: a native chat tab backed by BrowserAgentManager.
//
// Spin-up (from the omnibox): we open the agent tab in the background —
// visible in the sidebar, fruit icon "working", but NOT focused — capture what
// the user was looking at (URL, selection, viewport text) into the agent's
// system prompt, and send the query. The agent itself decides how to deliver:
// it can focus its own tab via `browser.tabs.activate(...)` and answer in
// chat, or perform a navigation and dismiss itself with the `done` tool.

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
    public static func ask(query: String, windowID: ID<WindowState>) {
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
            BrowserStore.shared.modify { st in
                let pid = ID<WebContent>.assign()
                paneID = pid
                var info = WebContent.Info(url: url)
                info.agentIsWorking = true
                var tab = Tab(id: .assign(), panes: [Pane(id: pid, info: info)])
                // Without this a never-activated tab fails the
                // validLiveWebContentIds check and gets its WebContent evicted.
                tab.lastActiveInWindow = windowID
                let loc = st.insertionIndex(window: windowID, spawningTabId: st.windows[windowID]?.currentTab)
                st.insertTab(tab, location: loc, inWindow: windowID)
                // Deliberately not activated — the agent focuses itself if needed.
            }
        }

        let session = AgentChatSession.session(forKey: key)
        session.begin(query: query, ownPaneID: paneID, sourcePaneID: sourcePaneID, ownTabIsFocused: reusedCurrentTab)
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

    public let key: String
    @Published public private(set) var messages: [BrowserJSAgentMessage] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorText: String?

    /// Scroll offset of the transcript, preserved across view remounts.
    public var savedScrollY: CGFloat?

    private var agentID: String?
    private var nextIndex = 0
    private var turnLoopTask: Task<Void, Never>?
    private var didBegin = false

    private init(key: String) {
        self.key = key
    }

    /// Spin up a fresh agent for a new "ask" — context capture, create, send.
    func begin(query: String, ownPaneID: ID<WebContent>, sourcePaneID: ID<WebContent>?, ownTabIsFocused: Bool) {
        guard !didBegin else { return }
        didBegin = true
        setWorking(true)
        Task {
            let context = await AgentChatSession.capturePageContext(paneID: sourcePaneID)
            do {
                let options = BrowserJSAgentCreateOptions(
                    key: key,
                    name: query,
                    systemPrompt: AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: query).url.absoluteString,
                        sourcePaneID: sourcePaneID,
                        ownTabIsFocused: ownTabIsFocused,
                        pageContext: context
                    )
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
        AgentChatTabs.installToolsIfNeeded()
        Task {
            do {
                let options = BrowserJSAgentCreateOptions(
                    key: key,
                    systemPrompt: AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: nil).url.absoluteString,
                        sourcePaneID: nil,
                        ownTabIsFocused: true,
                        pageContext: nil
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
                    return
                }
            }
        }
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
        BrowserStore.shared.modify { st in
            if let pid = st.agentChatPane(forKey: key) {
                st.modifyPaneAndTab(forWebContentId: pid) { pane, _ in
                    if pane.info.agentIsWorking != working { pane.info.agentIsWorking = working }
                    if pane.info.agentStatusDetail != detail { pane.info.agentStatusDetail = detail }
                }
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

    private static func systemPrompt(ownPaneID: ID<WebContent>, agentURL: String, sourcePaneID: ID<WebContent>?, ownTabIsFocused: Bool, pageContext: String?) -> String {
        let own = ownPaneID.raw
        var prompt = """
        You are a quick, helpful in-browser agent inside the Wowser browser. The \
        user asked you something from the address bar. Your chat lives in its own \
        tab — tab id "\(own)", url "\(agentURL)" — \
        \(ownTabIsFocused
            ? "which the user is already looking at."
            : "which is currently OPEN IN THE BACKGROUND, NOT focused.")

        FIRST choose the right presentation for your response, then act:

        """
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


        Be concise and direct — this is a small chat pane, not a document. Use \
        the page context below when the user says "this". Only reach for other \
        browser tools when they actually help.
        """
        if let pageContext {
            prompt += "\n\n" + pageContext
        }
        return prompt
    }
}
