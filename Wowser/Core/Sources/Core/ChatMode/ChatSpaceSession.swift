import Foundation
import Combine
import SwiftUI

// The coordinator agent behind a chat-mode space.
//
// One per space (profile). The sidebar renders `entries` — the persisted
// thread from ChatThreadStore — and sends the user's messages here. The
// session owns the keyed BrowserAgentManager agent ("chatspace-<profile>"),
// mirrors its transcript into the store as it streams, watches the space's
// tabs so every tab the user can see has a card in the thread, and keeps an
// event log ("user switched to X", "tab closed") that is prepended to the
// next message so the coordinator has ambient awareness of the browser.

@MainActor
public final class ChatSpaceSession: ObservableObject {
    private static var sessions: [ID<Profile>: ChatSpaceSession] = [:]

    public static func session(for profileID: ID<Profile>) -> ChatSpaceSession {
        if let existing = sessions[profileID] { return existing }
        let s = ChatSpaceSession(profileID: profileID)
        sessions[profileID] = s
        return s
    }

    /// The live session for a coordinator key, if one has been created.
    static func existingSession(forKey key: String) -> ChatSpaceSession? {
        guard let pid = ChatAgentRegistry.profileID(forCoordinatorKey: key) else { return nil }
        return sessions[pid]
    }

    public let profileID: ID<Profile>
    public var key: String { ChatAgentRegistry.coordinatorKey(for: profileID) }

    @Published public private(set) var entries: [ChatThreadEntry] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusDetail: String?
    @Published public private(set) var errorText: String?
    /// Scroll offset of the transcript, preserved across view remounts.
    public var savedScrollY: CGFloat?

    private var agentID: String?
    private var creating: Task<String?, Never>?
    private var nextIndex = 0
    private var windowID: ID<WindowState>?
    private var subscriptions = Set<AnyCancellable>()
    private var tabObservation: AnyCancellable?

    // Ambient awareness
    private var pendingEvents: [String] = []
    private var knownTabIDs: Set<ID<Tab>> = []
    private var lastCurrentTab: ID<Tab>?
    private var lastSeenInfo: [ID<Tab>: (url: URL?, title: String?)] = [:]
    private var seededTabs = false

    private init(profileID: ID<Profile>) {
        self.profileID = profileID
        entries = ChatThreadStore.shared.thread(for: profileID).entries
        ChatThreadStore.shared.uiPublisher
            .map { $0.threads[profileID]?.entries ?? [] }
            .removeDuplicates()
            .sink { [weak self] in self?.entries = $0 }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .browserAgentDidUpdate)
            .compactMap { $0.userInfo?["key"] as? String }
            .filter { [weak self] in $0 == self?.key }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pullTranscript() }
            .store(in: &subscriptions)
    }

    // MARK: - Lifecycle

    /// Called when the chat-mode sidebar for this space appears in `windowID`.
    /// Creates (or resumes) the coordinator agent and starts watching tabs.
    public func attach(windowID: ID<WindowState>) {
        self.windowID = windowID
        observeTabsIfNeeded()
        Task { _ = await ensureAgent() }
    }

    /// The coordinator's agent id, creating/resuming the agent on first use.
    func ensureAgent() async -> String? {
        if let agentID { return agentID }
        if let creating { return await creating.value }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            AgentChatTabs.installToolsIfNeeded()
            let options = BrowserJSAgentCreateOptions(
                key: self.key,
                name: "Coordinator",
                effort: "low",
                systemPrompt: self.systemPrompt()
            )
            do {
                let id = try await BrowserAgentManager.shared.create(options: options)
                self.agentID = id
                self.pullTranscript()
                return id
            } catch {
                self.errorText = error.localizedDescription
                return nil
            }
        }
        creating = task
        let id = await task.value
        creating = nil
        return id
    }

    // MARK: - Sending

    public func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorText = nil
        setWorking(true)
        let context = takeContextBlock()
        Task {
            guard let id = await ensureAgent() else { setWorking(false); return }
            do {
                try await BrowserAgentManager.shared.send(
                    id: id,
                    text: context.isEmpty ? trimmed : context + "\n\n" + trimmed,
                    images: [],
                    displayText: trimmed
                )
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

    /// Wipe the thread and start a fresh conversation (the agent session is
    /// disposed so it forgets too).
    public func clearThread() {
        ChatThreadStore.shared.clear(profileID: profileID)
        pendingEvents.removeAll()
        let id = agentID
        agentID = nil
        nextIndex = 0
        setWorking(false)
        Task {
            if let id { try? await BrowserAgentManager.shared.dispose(id: id) }
            _ = await ensureAgent()
        }
        // Re-seed cards for the tabs that are still open.
        seededTabs = false
        knownTabIDs.removeAll()
        seedTabsIfNeeded()
    }

    // MARK: - Cards & events (called by the browser, not the agent)

    /// Append a card for `tabID` at the bottom of the thread. With `force`
    /// false, no-op if the tab already has a card anywhere in the thread.
    public func addCard(tabID: ID<Tab>, note: String? = nil, force: Bool = false) {
        let state = BrowserStore.shared.model
        guard let tab = state.tabs[tabID] else { return }
        let thread = ChatThreadStore.shared.thread(for: profileID)
        if !force, thread.hasCard(for: tabID) { return }
        if force, let last = thread.entries.last(where: { $0.role == "tab_card" }), last.tabID == tabID, note == nil { return }
        let pane = tab.focusedPane ?? tab.panes.first
        let title = tab.appearance().title
        ChatThreadStore.shared.append(ChatThreadEntry(
            role: "tab_card",
            text: note ?? "",
            tabID: tabID,
            url: pane?.info.url,
            title: title
        ), to: profileID)
        knownTabIDs.insert(tabID)
    }

    public func recordEvent(_ text: String) {
        pendingEvents.append(text)
        if pendingEvents.count > 40 { pendingEvents.removeFirst(pendingEvents.count - 40) }
    }

    /// The hidden context prepended to the user's next message.
    private func takeContextBlock() -> String {
        let state = BrowserStore.shared.model
        var lines: [String] = ["[Browser context — automatic, not written by the user]"]
        if let windowID, let win = state.windows[windowID], let tabID = win.currentTab, let tab = state.tabs[tabID] {
            let pane = tab.focusedPane ?? tab.panes.first
            let title = tab.appearance().title
            let url = pane?.info.url?.absoluteString ?? "(no url)"
            lines.append("Current tab: \"\(title)\" \(url) — tab id \(pane?.id.raw ?? "?")")
            if tab.panes.count > 1 {
                lines.append("(It's a split of \(tab.panes.count) panes: " + tab.panes.map { "\($0.id.raw) \($0.info.url?.absoluteString ?? "")" }.joined(separator: "; ") + ")")
            }
        } else {
            lines.append("Current tab: none selected")
        }
        if !pendingEvents.isEmpty {
            lines.append("Since your last message:")
            lines.append(contentsOf: pendingEvents.map { "- " + $0 })
        }
        lines.append("[End of browser context]")
        pendingEvents.removeAll()
        return lines.joined(separator: "\n")
    }

    // MARK: - Tab observation

    private struct TabsSnapshot: Equatable {
        var tabs: [ID<Tab>]
        var currentTab: ID<Tab>?
        var info: [ID<Tab>: TabInfoLite]
        var ghost: Set<ID<Tab>>
    }
    private struct TabInfoLite: Equatable {
        var url: URL?
        var title: String
    }

    private func observeTabsIfNeeded() {
        guard tabObservation == nil, let windowID else { return }
        let pid = profileID
        tabObservation = BrowserStore.shared.uiPublisher
            .map { state -> TabsSnapshot in
                let tabs = state.windows[windowID]?.perProfileData[pid]?.tabs ?? []
                var info: [ID<Tab>: TabInfoLite] = [:]
                var ghost = Set<ID<Tab>>()
                for id in tabs {
                    guard let tab = state.tabs[id] else { continue }
                    let pane = tab.focusedPane ?? tab.panes.first
                    info[id] = TabInfoLite(url: pane?.info.url, title: tab.appearance().title)
                    if tab.panes.allSatisfy({ $0.isGhost }) { ghost.insert(id) }
                }
                return TabsSnapshot(tabs: tabs, currentTab: state.windows[windowID]?.perProfileData[pid]?.currentTab, info: info, ghost: ghost)
            }
            .removeDuplicates()
            .sink { [weak self] snap in self?.tabsDidChange(snap) }
    }

    private func seedTabsIfNeeded() {
        guard !seededTabs, let windowID else { return }
        seededTabs = true
        let state = BrowserStore.shared.model
        let tabs = state.windows[windowID]?.perProfileData[profileID]?.tabs ?? []
        for id in tabs {
            guard let tab = state.tabs[id] else { continue }
            knownTabIDs.insert(id)
            if !tab.panes.allSatisfy({ $0.isGhost }) {
                addCard(tabID: id)
            }
        }
        lastCurrentTab = state.windows[windowID]?.perProfileData[profileID]?.currentTab
    }

    private func tabsDidChange(_ snap: TabsSnapshot) {
        if !seededTabs {
            seedTabsIfNeeded()
        }
        let current = Set(snap.tabs)
        // Newly visible (non-ghost) tabs get a card. Ghost tabs stay hidden
        // until an agent presents them or the user activates them.
        for id in snap.tabs where !knownTabIDs.contains(id) && !snap.ghost.contains(id) {
            addCard(tabID: id)
            if let info = snap.info[id] {
                recordEvent("Tab opened: \"\(info.title)\" \(info.url?.absoluteString ?? "")")
            }
        }
        // Closed tabs.
        for id in knownTabIDs where !current.contains(id) {
            if let info = lastSeenInfo[id] {
                recordEvent("Tab closed: \"\(info.title ?? "")\" \(info.url?.absoluteString ?? "")")
                ChatThreadStore.shared.updateCard(tabID: id, url: info.url, title: info.title)
            }
            knownTabIDs.remove(id)
            lastSeenInfo[id] = nil
        }
        for (id, info) in snap.info { lastSeenInfo[id] = (info.url, info.title) }
        // Ghost tabs aren't "known" until they become visible, so a later
        // promotion (agent presents it / user activates it) gets a card.
        knownTabIDs.formUnion(snap.tabs.filter { !snap.ghost.contains($0) })

        if snap.currentTab != lastCurrentTab {
            lastCurrentTab = snap.currentTab
            if let id = snap.currentTab, let info = snap.info[id] {
                recordEvent("User switched to tab: \"\(info.title)\" \(info.url?.absoluteString ?? "")")
            }
        }
    }

    // MARK: - Transcript mirroring

    private func pullTranscript() {
        guard let agentID else { return }
        Task {
            let messages = (try? await BrowserAgentManager.shared.messages(id: agentID, since: nextIndex)) ?? []
            let status = await BrowserAgentManager.shared.status(id: agentID)
            self.merge(messages)
            self.setWorking(status == "running")
        }
    }

    private func merge(_ messages: [BrowserJSAgentMessage]) {
        let state = BrowserStore.shared.model
        for m in messages where m.index >= nextIndex {
            nextIndex = m.index + 1
            switch m.role {
            case "user", "assistant", "peer", "error", "stopped", "tool_use":
                if m.text.isEmpty && m.role != "tool_use" { continue }
                ChatThreadStore.shared.append(ChatThreadEntry(role: m.role, text: m.text, toolName: m.toolName), to: profileID)
                if m.role == "error" { errorText = m.text }
            case "tab_card":
                let paneID = ID<WebContent>(raw: m.text)
                if let tabID = state.paneToTabMapping[paneID] {
                    addCard(tabID: tabID, note: m.toolName?.nilIfEmpty, force: true)
                }
            default:
                break // thinking, tool_result: not shown
            }
            statusDetail = Self.statusDetail(for: m)
        }
    }

    private static func statusDetail(for message: BrowserJSAgentMessage) -> String? {
        switch message.role {
        case "thinking": return "Thinking…"
        case "assistant": return "Writing…"
        case "tool_use":
            switch message.toolName {
            case "run_browser_js": return "Driving the browser…"
            case .some(let name): return "Using \(name)…"
            case nil: return "Using a tool…"
            }
        default: return nil
        }
    }

    private func setWorking(_ working: Bool) {
        if isWorking != working { isWorking = working }
        if !working { statusDetail = nil }
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        let state = BrowserStore.shared.model
        let profile = state.profiles[profileID]
        let spaceName = profile?.title?.nilIfEmpty ?? profile?.autoTitle ?? "this space"
        let folder = profile?.folderPath
        return """
        You are the COORDINATOR of a chat-mode space ("\(spaceName)") in the Wowser browser. \
        Your chat IS the user's sidebar: instead of a tab list, they see this thread, and every \
        tab in the space appears in it as a tab CARD. Your session key is "\(key)" (space id "\(profileID.raw)").

        ## Your job
        You are the user's guide around the web and the dispatcher for everything that takes real \
        work. When the user types something, decide: open pages for them, answer briefly, or hand \
        the work off as a TASK (a background agent you spawn). Keep your replies short — this is a \
        narrow sidebar, not a document. Prefer showing a page over describing it.

        ## Hard rules
        1. NEVER do slow work yourself. Anything that would take more than ~5 seconds — reading \
        several pages, research, comparisons, coding, builds, long terminal commands, anything \
        iterative — becomes a task via `browser.agents.spawn({ task, name })`. You are a \
        dispatcher; you stay responsive. Give the task a complete, self-contained description. \
        It will `agents.send` you its result when done — you do not wait for it; just tell the \
        user what you kicked off and end your turn. Always call them "tasks" when talking to the \
        user, never "agents" or "subagents".
        2. Show pages with `browser.present(...)`. `present({ url })` opens a page and drops a \
        card in this thread; `present({ url, show: 'main' })` opens it in the main view; \
        `show: 'both'` does both. When the user asks to open/see/go to something, use \
        `show: 'both'`.
        3. Searches and questions ("look up X", "what's the best Y", anything you'd answer from \
        the web): FIRST present a search results page for the query in the main view \
        (`show: 'both'`), so the user sees results immediately. THEN open the two or three most \
        promising result pages as background tabs in this space (`present({ url })` for each — \
        no `show: 'main'`, so they appear as cards here without stealing the main view), read \
        them with `browser.content.read`, and start \
        answering the user from what you found — a sentence or two with the key facts, citing the \
        pages as links. The pages you opened stay in the thread as cards so the user can jump in. \
        If the answer needs more than a quick read of a few pages, spawn a task for the deeper \
        research after giving the quick first take.
        4. Tabs opened in this space (by you or the user) automatically get cards here. Use \
        `browser.tabs.openGhost` only for pages you need to read privately; present them if the \
        user should see them.
        5. Terminal work: `browser.terminal.open({ cwd, command })` opens a real shell tab; \
        `terminal.read(id, { since: token })` returns new output; `terminal.write(id, text)` types \
        into it. Use these for quick one-liners only; anything longer is a task's job \
        (tasks have the same terminal tools, and can run `claude` in a terminal tab for coding).
        6. Messages that start with "[Message from agent …]" come from tasks, not the user. \
        Relay what matters to the user in a sentence or two, and present any pages they mention.
        7. Each user message is preceded by a "[Browser context …]" block written by the browser: \
        the current tab and what changed since your last message. Use it to know what "this page" \
        means; never quote it back.

        8. NEVER send the user more than ~8 lines of chat. When you have more to say — a \
        comparison, a list of options, a summary of what tasks found, a plan — write it up as a \
        note with `browser.notes.write({ title, markdown })` (it opens in the main view and drops \
        a card here) and reply with one or two sentences pointing at it. Notes are markdown: use \
        headings, lists, and links freely there.

        ## Style
        - One to three sentences per reply. No headers. EVERY URL or page you mention must be a \
        markdown link (`[title](url)`) — never a bare URL; clicking a link in this thread opens it \
        as a tab. The same goes for notes you write and for anything you relay from a task.
        - Don't narrate tool calls. Don't ask permission for routine actions like opening a page.
        - Always end your turn promptly after dispatching work.
        \(folder.map { "\n## Space folder\nThis space is attached to the folder `\($0)` — use it as the default cwd/workingDirectory for terminals and coding tasks." } ?? "")
        """
    }
}
