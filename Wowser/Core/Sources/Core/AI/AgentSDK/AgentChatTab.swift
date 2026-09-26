import Foundation
import UniformTypeIdentifiers
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

    /// Runs a scheduled task in a real (non-activated) background tab of
    /// `windowID`. The tab stays open after the run so the user can inspect
    /// it; the scheduler closes it when the task next runs. Returns the
    /// agent key (used to close that tab later). `completion` receives the
    /// agent's final text (or error) when the turn ends.
    @discardableResult
    public static func startScheduledTask(_ task: ScheduledTask, windowID: ID<WindowState>, completion: @escaping (_ result: ScheduledTaskRunResult) -> Void) -> String {
        installToolsIfNeeded()
        let key = keyPrefix + "task-" + String(UUID().uuidString.lowercased().prefix(8))
        let url = NativePageKey.agent(key: key, query: task.title).url
        var paneID: ID<WebContent>?
        BrowserStore.shared.modify { st in
            let tab = st.openTab(url: url, activate: false, windowID: windowID)
            paneID = tab.panes.first?.id
            if let paneID { st.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in pane.info.agentIsWorking = true } }
        }
        guard let paneID else { return key }
        // Materialize the WebContent so the tab survives the unloader and the
        // chat view mounts warm when the user visits it.
        if let wc = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID) {
            wc.info.agentIsWorking = true
        }
        let session = AgentChatSession.session(forKey: key)
        session.onScheduledTaskFinished = completion
        session.begin(
            query: task.prompt,
            ownPaneID: paneID,
            sourcePaneID: nil,
            ownTabIsFocused: false,
            mode: .scheduledTask(AgentChatSession.ScheduledTaskRunSpec(
                title: task.title,
                dataFilePath: ScheduledTasksStore.dataFileURL(taskID: task.id).path,
                tasksFilePath: ScheduledTasksStore.fileURL.path
            ))
        )
        return key
    }

    /// Creates a working agent tab hidden behind the omnibox of `windowID`.
    static func insertAttachedTab(key: String, url: URL, windowID: ID<WindowState>) -> ID<WebContent> {
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

    /// Sidebar "chat" button: open a fresh chat in a split beside the window's
    /// current tab and focus it. If that tab already has a chat pane, focus it
    /// instead; if the current pane is an empty new tab, take it over.
    public static func openChatSplit(windowID: ID<WindowState>) {
        installToolsIfNeeded()
        let key = keyPrefix + String(UUID().uuidString.lowercased().prefix(8))
        let url = NativePageKey.agent(key: key, query: nil).url
        var paneID: ID<WebContent>?
        BrowserStore.shared.modify { st in
            paneID = st.openChatSplit(url: url, inWindow: windowID)
        }
        if let paneID, let wc = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID),
           wc.info.url != url {
            wc.load(url: url)
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
                // In a chat-mode space the sidebar is the coordinator thread;
                // collapse it so the split has room.
                if st.isChatMode {
                    st.windows[winID]?.sidebarLocked = false
                }
            }
        }
    }

    /// Spawn a subagent as a new agent tab in `windowID` and start it on `task`.
    /// Returns the session key and pane. See `browser.agents.spawn`.
    static func spawnSubagent(task: String, spec: AgentChatSession.SubagentSpec, windowID: ID<WindowState>, spawningPaneID: ID<WebContent>? = nil, background: Bool, ghost: Bool) -> (key: String, paneID: ID<WebContent>) {
        installToolsIfNeeded()
        let key = ChatAgentRegistry.subagentPrefix + String(UUID().uuidString.lowercased().prefix(8))
        let url = NativePageKey.agent(key: key, query: spec.name).url
        let pid = ID<WebContent>.assign()
        BrowserStore.shared.modify { st in
            var info = WebContent.Info(url: url)
            info.agentIsWorking = true
            var pane = Pane(id: pid, info: info)
            pane.isGhost = ghost
            var tab = Tab(id: .assign(), panes: [pane])
            tab.lastActiveInWindow = windowID
            let loc = st.spawnInsertionIndex(window: windowID, spawningPaneID: spawningPaneID)
            st.insertTab(tab, location: loc, inWindow: windowID)
            if !background {
                st.activate(tabId: tab.id, in: windowID)
            }
        }
        if let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: windowID) {
            wc.info.agentIsWorking = true
        }
        ChatAgentRegistry.register(key: key, name: spec.name, parentKey: spec.parentKey, paneID: pid)
        let session = AgentChatSession.session(forKey: key)
        session.begin(query: task, ownPaneID: pid, sourcePaneID: nil, ownTabIsFocused: !background, mode: .subagent(spec))
        return (key, pid)
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
    /// Puts an agent chat at `url` beside the window's current tab and focuses
    /// it. Reuses an existing chat pane in that split, or takes over an empty
    /// new-tab pane. Returns the pane showing the chat (nil if the window has
    /// no current tab; then a new tab is opened instead).
    mutating func openChatSplit(url: URL, inWindow windowID: ID<WindowState>) -> ID<WebContent>? {
        guard let tabID = windows[windowID]?.currentTab, let tab = tabs[tabID] else {
            return openTab(url: url, activate: true, windowID: windowID).panes.first?.id
        }
        if let existing = tab.panes.elements.firstIndex(where: { $0.info.url.flatMap(NativePageKey.init)?.isAgent == true }) {
            modifyTab(id: tabID) { $0.focusedPaneIdx = existing }
            return tab.panes[existing]?.id
        }
        if let current = tab.panes[tab.focusedPaneIdx], current.info.isEmptyPage {
            modifyPaneAndTab(forWebContentId: current.id) { pane, _ in pane.info = WebContent.Info(url: url) }
            return current.id
        }
        let pane = Pane(id: .assign(), info: .init(url: url))
        modifyTab(id: tabID) { t in
            t.panes.append(pane)
            t.focusedPaneIdx = t.panes.count - 1
        }
        // In a chat-mode space the sidebar is the coordinator thread; collapse
        // it so the split has room.
        if isChatMode {
            windows[windowID]?.sidebarLocked = false
        }
        return pane.id
    }

    /// The first non-chat pane sharing a split with `paneID`, if any.
    func splitSibling(ofPane paneID: ID<WebContent>) -> Pane? {
        guard let tabID = paneToTabMapping[paneID], let tab = tabs[tabID] else { return nil }
        return tab.panes.elements.first { $0.id != paneID && $0.info.url.flatMap(NativePageKey.init)?.isAgent != true }
    }

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
        if let token = sessions[key]?.notificationToken { NotificationCenter.default.removeObserver(token) }
        sessions[key] = nil
        ChatAgentRegistry.unregister(key: key)
    }

    public enum Mode: Equatable {
        /// A question typed (or dictated) into the omnibox.
        case ask(dictated: Bool)
        /// A follow-up "New Chat" tab the user opened deliberately.
        case chat
        /// A background run of a scheduled task.
        case scheduledTask(ScheduledTaskRunSpec)
        /// A subagent spawned by another agent via `browser.agents.spawn`.
        case subagent(SubagentSpec)
        /// Authoring, fixing, or acting on a user-created toolbar button.
        case toolbarButton(ToolbarButtonJob)
    }

    public struct ScheduledTaskRunSpec: Equatable {
        public var title: String
        public var dataFilePath: String
        public var tasksFilePath: String
    }

    public struct SubagentSpec: Equatable {
        public var parentKey: String
        public var name: String
        public var model: String?
        public var effort: String?
        public var fileSystemTools: Bool
        public var workingDirectory: String?
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
    /// The page the user asked from (omnibox asks), for agents that act on it.
    private(set) var sourcePaneID: ID<WebContent>?
    private var nextIndex = 0
    private var turnLoopTask: Task<Void, Never>?
    private var didBegin = false
    private var turnsCompleted = 0

    private var notificationToken: NSObjectProtocol?

    /// The split sibling the agent was last told about (nil = told there is
    /// none, or never told). Compared at send time so the agent hears about a
    /// change exactly once, with the sibling's URL as of that moment.
    private var reportedSiblingID: ID<WebContent>?
    private var didReportSibling = false

    private init(key: String) {
        self.key = key
        notificationToken = NotificationCenter.default.addObserver(forName: .browserAgentDidUpdate, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["key"] as? String == key else { return }
            Task { @MainActor in
                guard let id = self.agentID else { return }
                let status = await BrowserAgentManager.shared.status(id: id)
                if status == "running", !self.isWorking {
                    self.externalTurnDidStart()
                } else if self.turnLoopTask == nil {
                    // Not mid-turn: pick up locally appended entries (tab cards).
                    let new = (try? await BrowserAgentManager.shared.messages(id: id, since: self.nextIndex)) ?? []
                    self.mergeMessages(new)
                }
            }
        }
    }

    /// Spin up a fresh agent for a new "ask" — context capture, create, send.
    func begin(query: String, ownPaneID: ID<WebContent>, sourcePaneID: ID<WebContent>?, ownTabIsFocused: Bool, mode: Mode) {
        guard !didBegin else { return }
        didBegin = true
        self.mode = mode
        self.ownPaneID = ownPaneID
        self.sourcePaneID = sourcePaneID
        setWorking(true)
        Task {
            let context = isScheduledTask ? nil : await AgentChatSession.capturePageContext(paneID: sourcePaneID)
            do {
                let prompt: String
                switch mode {
                case .scheduledTask(let spec):
                    prompt = AgentChatSession.scheduledTaskSystemPrompt(
                        spec: spec,
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
                case .toolbarButton(let job):
                    prompt = AgentChatSession.toolbarButtonSystemPrompt(
                        job: job,
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: job.title).url.absoluteString,
                        pageContext: context
                    )
                case .subagent(let spec):
                    prompt = AgentChatSession.subagentSystemPrompt(
                        key: key,
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: spec.name).url.absoluteString,
                        spec: spec
                    )
                }
                var displayName = query
                if case .scheduledTask(let spec) = mode { displayName = "Task: " + String(spec.title.prefix(60)) }
                if case .toolbarButton(let job) = mode { displayName = job.title }
                var options = BrowserJSAgentCreateOptions(
                    key: key,
                    name: displayName,
                    effort: isScheduledTask ? "medium" : "low",
                    systemPrompt: prompt,
                    workingDirectory: BrowserStore.shared.model.spaceFolderPath(forWebContentId: ownPaneID)
                )
                switch mode {
                case .ask, .chat: options.harness = AgentHarness.current.createOptionsValue
                case .scheduledTask, .subagent, .toolbarButton: break
                }
                if case .subagent(let spec) = mode {
                    options.name = spec.name
                    options.model = spec.model
                    options.effort = spec.effort ?? "medium"
                    options.fileSystemTools = spec.fileSystemTools
                    options.workingDirectory = spec.workingDirectory ?? options.workingDirectory
                }
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
        // The same chat can move panes (the agent re-opens itself as a split
        // and closes the original) — always track the pane that's showing it.
        self.ownPaneID = ownPaneID
        guard !didBegin else { return }
        didBegin = true
        AgentChatTabs.installToolsIfNeeded()
        // A chat opened straight into a split (sidebar button) learns its
        // sibling up front; later changes arrive as events on the next message.
        let sibling = BrowserStore.shared.model.splitSibling(ofPane: ownPaneID)
        reportedSiblingID = sibling?.id
        didReportSibling = true
        Task {
            do {
                var options = BrowserJSAgentCreateOptions(
                    key: key,
                    effort: "low",
                    systemPrompt: AgentChatSession.systemPrompt(
                        ownPaneID: ownPaneID,
                        agentURL: NativePageKey.agent(key: key, query: nil).url.absoluteString,
                        sourcePaneID: nil,
                        ownTabIsFocused: true,
                        pageContext: sibling.map(AgentChatSession.splitSiblingContext),
                        dictated: false
                    ),
                    workingDirectory: BrowserStore.shared.model.spaceFolderPath(forWebContentId: ownPaneID)
                )
                options.harness = AgentHarness.current.createOptionsValue
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

    /// A turn was started on this agent from outside the chat UI (a peer
    /// agent's `agents.send`, or the coordinator). Show it as working and
    /// stream its transcript.
    func externalTurnDidStart() {
        guard agentID != nil else { return }
        errorText = nil
        setWorking(true)
        runTurnLoop()
    }

    /// Send a follow-up message typed in the chat. Image attachments go to
    /// the model as image blocks; other files are listed by path so the agent
    /// can read them itself.
    public func send(text: String, attachments: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let agentID else { return }
        errorText = nil
        setWorking(true)
        ChatAgentRegistry.resetTurnFlags(key: key)
        let event = takeSplitSiblingEvent()
        Task {
            let loaded = await Task.detached { Self.loadAttachments(attachments) }.value
            var parts: [String] = []
            if let event { parts.append(event) }
            if !trimmed.isEmpty { parts.append(trimmed) }
            if !loaded.filePaths.isEmpty {
                parts.append("Attached files (read them as needed):\n" + loaded.filePaths.map { "- " + $0 }.joined(separator: "\n"))
            }
            var display = trimmed
            if !loaded.fileNames.isEmpty {
                display += (display.isEmpty ? "" : " ") + "📎 " + loaded.fileNames.joined(separator: ", ")
            }
            do {
                try await BrowserAgentManager.shared.send(
                    id: agentID,
                    text: parts.joined(separator: "\n\n"),
                    images: loaded.images,
                    displayText: display
                )
                self.runTurnLoop()
            } catch {
                self.errorText = error.localizedDescription
                self.setWorking(false)
            }
        }
    }

    private struct LoadedAttachments: Sendable {
        var images: [BrowserJSImage] = []
        var filePaths: [String] = []
        var fileNames: [String] = []
    }

    private nonisolated static func loadAttachments(_ urls: [URL]) -> LoadedAttachments {
        var out = LoadedAttachments()
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if let type, type.conforms(to: .image), let mime = type.preferredMIMEType,
               ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
               let data = try? Data(contentsOf: url) {
                out.images.append(BrowserJSImage(mime: mime, data: data.base64EncodedString()))
            } else {
                out.filePaths.append(url.path)
            }
            out.fileNames.append(url.lastPathComponent)
        }
        return out
    }

    public func interrupt() {
        guard let agentID else { return }
        Task { try? await BrowserAgentManager.shared.interrupt(id: agentID) }
    }

    // MARK: - Split sibling events

    /// If the pane beside this chat differs from the one the agent last heard
    /// about, an event line describing the change (the first time, and
    /// whenever it changes). Marks it reported.
    private func takeSplitSiblingEvent() -> String? {
        guard let ownPaneID else { return nil }
        let sibling = BrowserStore.shared.model.splitSibling(ofPane: ownPaneID)
        guard !didReportSibling || sibling?.id != reportedSiblingID else { return nil }
        didReportSibling = true
        reportedSiblingID = sibling?.id
        if let sibling {
            return "[Browser event] " + AgentChatSession.splitSiblingContext(sibling)
        }
        return "[Browser event] This chat is no longer in a split — there is no page beside it."
    }

    static func splitSiblingContext(_ pane: Pane) -> String {
        let url = pane.info.url?.absoluteString ?? ""
        let title = pane.info.title?.nilIfEmpty
        return "This chat is shown in a SPLIT beside the user's page: tab id \"\(pane.id.raw)\"" +
            (title.map { ", \"\($0)\"" } ?? "") + (url.isEmpty ? "" : ", \(url)") +
            ". Use that id with browser.content.read / browser.page.* / browser.tabs.navigate to read or act on it when the user says \"this\"."
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
            if isScheduledTask { finishScheduledTask(result: result) }
            return
        }
        let stillAttached = state.isAttachedAgentTab(tabID)

        switch mode {
        case .scheduledTask:
            // The run's tab is a normal background tab; it stays open until
            // the task next runs (the scheduler closes it then).
            finishScheduledTask(result: result)
        case .subagent(let spec):
            // Safety net: a subagent that finished without reporting to its
            // parent gets its final answer forwarded, so the parent (and the
            // user, via the coordinator) always hears back.
            let reported = ChatAgentRegistry.record(forKey: key)?.reportedToParentThisTurn ?? false
            ChatAgentRegistry.resetTurnFlags(key: key)
            let final = (result.text?.nilIfEmpty ?? messages.last(where: { $0.role == "assistant" })?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !reported, !final.isEmpty {
                Task {
                    try? await BrowserJSLiveHost.shared.agentsSend(agentKey: key, toKey: spec.parentKey, text: (result.isError ? "[failed] " : "[finished] ") + final)
                }
            }
        case .toolbarButton(let job) where !job.isClick:
            // Authoring / repairing a button is headless: vanish when done,
            // surface only if something went wrong.
            ToolbarButtonAgentStatus.shared.setWorking(job.button.id, false)
            guard stillAttached else { return }
            if result.isError || errorText != nil {
                BrowserStore.shared.modify { st in st.detachAgentTab(tabID: tabID, inWindow: winID) }
            } else {
                AgentChatTabs.close(key: key)
            }
        case .ask, .chat, .toolbarButton:
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

    private var isScheduledTask: Bool {
        if case .scheduledTask = mode { return true }
        return false
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
            st.updatePaneInfo(forWebContentId: pid) { info in
                if info.agentIsWorking != working { info.agentIsWorking = working }
                if info.agentStatusDetail != detail { info.agentStatusDetail = detail }
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
        prompt += """
        If the user wants something done LATER or on a schedule ("every morning…", \
        "remind me Friday…"), register a scheduled task instead of doing it now: see \
        `browser.tasks` in the BrowserJS docs — `browser.tasks.list()` gives the \
        tasks.json path; read it, add the entry (id, title, self-contained prompt, \
        fireDates and/or recurrence), write it back, then confirm the schedule in a \
        sentence (chat answer). Editing or deleting tasks also goes through that file.

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

    private static func subagentSystemPrompt(key: String, ownPaneID: ID<WebContent>, agentURL: String, spec: SubagentSpec) -> String {
        """
        You are "\(spec.name)", a SUBAGENT inside the Wowser browser, spawned by another agent \
        (your parent, session key "\(spec.parentKey)") to do one task. Your session key is "\(key)". \
        Your chat lives in its own tab — tab id "\(ownPaneID.raw)", url "\(agentURL)" — which the \
        user may or may not be looking at. The task is the first message you receive.

        ## How to work
        - Do the task fully; you're the one meant to take time. Research with `browser.tabs.openGhost` \
        + `browser.content.read`, drive pages with `browser.page.*`, run shell work in terminal tabs \
        (`browser.terminal.open/read/write`), and for coding you can open a terminal running `claude` \
        and steer it by reading its output and typing into it.\(spec.fileSystemTools ? " You also have real file/shell tools in `\(spec.workingDirectory ?? "your working directory")`." : "")
        - Show the user pages with `browser.present({ url | tabId, show })`: 'card' drops a tab card into \
        your own chat; 'main' shows it in the main view (if the user is looking at YOUR tab, it opens \
        as a split beside you). Present the pages your result rests on.
        - REPORT BACK: when done (or blocked), call \
        `browser.agents.send({ key: "\(spec.parentKey)", text: <your result> })` with a concise result \
        the parent can relay to the user — findings, links, what you opened, and anything left \
        undone. Then write the same result here in chat and end your turn. Send interim progress \
        the same way for long jobs.
        - Messages starting with "[Message from agent …]" come from your parent (or another agent), \
        not the user; follow them.
        - Keep chat text concise. EVERY URL or page you mention — in chat and in what you send \
        back to your parent — must be a markdown link (`[title](url)`), never a bare URL.
        - For anything longer than a few lines (a comparison, a list, a write-up), use \
        `browser.notes.write({ title, markdown, show: 'card' })` and link to the note's url in \
        your result instead of pasting it all into chat.
        """
    }

    private static func toolbarButtonSystemPrompt(job: ToolbarButtonJob, ownPaneID: ID<WebContent>, agentURL: String, pageContext: String?) -> String {
        var prompt = """
        You are a quick, capable in-browser agent inside the Wowser browser, \
        working on behalf of one of the user's custom toolbar buttons. Your chat \
        lives in its own tab — tab id "\(ownPaneID.raw)", url "\(agentURL)" — \
        which is hidden behind the address bar unless you activate it.

        """
        if let pageContext { prompt += pageContext + "\n\n" }
        prompt += job.systemPromptSection(agentURL: agentURL, ownPaneID: ownPaneID.raw)
        return prompt
    }

    private static func scheduledTaskSystemPrompt(spec: ScheduledTaskRunSpec, ownPaneID: ID<WebContent>, agentURL: String) -> String {
        """
        You are a background agent inside the Wowser browser, running the \
        SCHEDULED TASK "\(spec.title)". The user is not watching and did not \
        just ask for this — work autonomously and never steal focus.

        Your chat lives in a background tab — tab id "\(ownPaneID.raw)", url \
        "\(agentURL)" — that the user can open later to see what you did. Use \
        `run_browser_js` to read and drive the browser.

        This task has a private data file for anything it needs to remember \
        between runs (what you've already seen, results so far, cursors, etc.):
            \(spec.dataFilePath)
        FIRST read it with `browser.fs.read` (it may not exist yet on the \
        first run — treat that as empty). Then do the task described in the \
        user message. LAST, write your updated state back to that same file \
        as JSON with `browser.fs.write`, so the next run can pick up where you \
        left off. Keep it compact.

        Do not open tabs for the user unless the task requires it, and never \
        activate tabs for routine work. If the task produces something the user \
        should read, write it with `browser.notes.write({ title, markdown, show: 'none' })` \
        and link to it in your final message. When you are done, write a one- or \
        two-sentence summary of what you did as your final message (this is \
        recorded as the run's status) and stop. Do NOT call `done`.

        The task's own definition lives in \(spec.tasksFilePath) (see \
        `browser.tasks` in the docs); only edit it if the task explicitly asks \
        you to reschedule or retire itself.
        """
    }
}

/// What a scheduled task run reported back when its agent turn ended.
public struct ScheduledTaskRunResult: Equatable {
    public var finishedAt: Date
    public var summary: String
    public var isError: Bool
}
