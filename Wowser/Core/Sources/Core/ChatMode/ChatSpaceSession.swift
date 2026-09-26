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
    /// Per-turn collapse state the user set by clicking a chevron, keyed by
    /// the user message's entry id. Turns without an entry here follow the
    /// sidebar's auto-collapse rule.
    @Published public var turnCollapseOverrides: [String: Bool] = [:]

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
    /// When the memory brief was last prepended (nil = not yet for this agent).
    private var lastMemoryBriefAt: Date?
    private static let memoryBriefInterval: TimeInterval = 10 * 60

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
        track(windowID: windowID)
        Task { _ = await ensureAgent() }
    }

    /// Start mirroring `windowID`'s tabs for this space into the thread (cards
    /// for new tabs, closed-tab events) without creating the coordinator.
    /// Called for every space a window shows, in both modes, so the thread is
    /// already current when chat mode is switched on. If the window we were
    /// watching is gone, retarget to the new one.
    public func track(windowID: ID<WindowState>) {
        if let current = self.windowID, current != windowID {
            guard BrowserStore.shared.model.windows[current] == nil else { return }
            tabObservation = nil
        }
        self.windowID = windowID
        observeTabsIfNeeded()
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
                systemPrompt: self.systemPrompt(),
                workingDirectory: BrowserStore.shared.model.profiles[self.profileID]?.folderPath
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
        let base = takeContextBlock()
        Task {
            guard let id = await ensureAgent() else { setWorking(false); return }
            let context = await self.enrichContext(base)
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

    /// Wipe the visible transcript only. The agent session is kept, so it
    /// still remembers the conversation; cards for open tabs are re-seeded.
    public func clearTranscript() {
        ChatThreadStore.shared.clear(profileID: profileID)
        errorText = nil
        savedScrollY = nil
        seededTabs = false
        knownTabIDs.removeAll()
        seedTabsIfNeeded()
    }

    /// Wipe the thread and start a fresh conversation (the agent session is
    /// disposed so it forgets too).
    public func clearThread() {
        ChatThreadStore.shared.clear(profileID: profileID)
        pendingEvents.removeAll()
        let id = agentID
        agentID = nil
        nextIndex = 0
        lastMemoryBriefAt = nil
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

    /// Async additions to the context block: text the user has selected in
    /// the current tab's panes, and (on the first message, then every ten
    /// minutes) the memory brief for this space.
    private func enrichContext(_ base: String) async -> String {
        var out = base
        let selections = await selectedTextInCurrentTab()
        if !selections.isEmpty {
            var lines = ["[Selected text — highlighted by the user right now]"]
            for (paneID, text) in selections {
                lines.append("In tab \(paneID):\n\"\"\"\n\(text)\n\"\"\"")
            }
            lines.append("[End of selected text]")
            out += "\n\n" + lines.joined(separator: "\n")
        }
        if let brief = await memoryBriefIfDue() {
            out += "\n\n" + brief
        }
        return out
    }

    /// `(paneID, selection)` for each web pane in the current tab with a
    /// non-empty selection. Native panes and about: pages are skipped.
    private func selectedTextInCurrentTab() async -> [(String, String)] {
        let state = BrowserStore.shared.model
        guard let windowID, let tabID = state.windows[windowID]?.perProfileData[profileID]?.currentTab, let tab = state.tabs[tabID] else { return [] }
        var out: [(String, String)] = []
        for pane in tab.panes {
            guard let url = pane.info.url, NativePageKey(url: url) == nil, !url.absoluteString.hasPrefix("about:"),
                  let webview = BrowserStore.shared.existingWebContent(forId: pane.id)?.wkWebview else { continue }
            let js = "(window.getSelection ? String(window.getSelection()) : '').slice(0, 3000)"
            guard let text = (try? await webview.evalReturningValue(js)) as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append((pane.id.raw, trimmed)) }
        }
        return out
    }

    private func memoryBriefIfDue() async -> String? {
        let state = BrowserStore.shared.model
        guard let profile = state.profiles[profileID], MemoryStore.shared.isEnabled(profile.dataStoreUUID) else { return nil }
        if let last = lastMemoryBriefAt, Date().timeIntervalSince(last) < Self.memoryBriefInterval { return nil }
        var tabs: [MemoryStore.BriefTab] = []
        if let windowID, let per = state.windows[windowID]?.perProfileData[profileID] {
            for id in per.tabs {
                guard let tab = state.tabs[id], !tab.panes.allSatisfy({ $0.isGhost }) else { continue }
                let pane = tab.focusedPane ?? tab.panes.first
                tabs.append(MemoryStore.BriefTab(tabID: id.raw, paneID: pane?.id.raw ?? "", title: tab.appearance().title,
                                                 url: pane?.info.url?.absoluteString, isCurrent: per.currentTab == id))
            }
        }
        var spaces: [MemoryStore.BriefSpace] = []
        if let windowID, let win = state.windows[windowID] {
            for p in state.profiles.values.filter({ !$0.isHidden }).sorted(by: { $0.creationOrder < $1.creationOrder }) {
                spaces.append(MemoryStore.BriefSpace(id: p.id.raw, name: p.displayName, tabCount: win.perProfileData[p.id]?.tabs.count ?? 0, isCurrent: p.id == profileID))
            }
        }
        guard let brief = await MemoryStore.shared.brief(scope: profile.dataStoreUUID, spaceID: profileID.raw, openTabs: tabs, spaces: spaces) else { return nil }
        lastMemoryBriefAt = Date()
        return brief
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
        the work off as a TASK (a background agent you spawn). Be SUPER concise, short, and \
        conversational — like a quick text from a sharp friend, not a document. Respond fast: \
        reply in seconds, and delegate anything slower to tasks. This is a narrow sidebar. \
        Prefer showing a page over describing it.

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
        means; never quote it back. It may be followed by a "[Selected text …]" block (what the \
        user has highlighted — usually what "this" refers to) and, now and then, a "[Memory brief …]" \
        block: a digest of the browser's memory log — recent pages and events from THIS space, the \
        open tabs, all spaces, and the user's top sites across every space. For anything the brief hints at but doesn't answer ("that article from yesterday", \
        "what did I type into X"), query the log with `browser.memory.query` as the brief describes.

        8. NEVER send the user more than ~8 lines of chat. When you have more to say — a \
        comparison, a list of options, a summary of what tasks found, a plan — write it up as a \
        note with `browser.notes.write({ title, markdown })` (it opens in the main view and drops \
        a card here) and reply with one or two sentences pointing at it. Notes are markdown: use \
        headings, lists, and links freely there.

        9. SCHEDULED TASKS: when the user wants something done later, at a set time, or on a \
        cadence ("every morning check…", "remind me Friday", "once a week…"), register a scheduled \
        task — see `browser.tasks` in the BrowserJS docs: `browser.tasks.list()` gives the \
        tasks.json path; read it, add/edit the entry (id, title, prompt, fireDates and/or \
        recurrence), and write it back. The prompt must be self-contained: a background agent runs \
        it with no other context and only its data file to remember prior runs. Confirm the \
        schedule in one sentence. Tasks appear in Settings › Tasks; the user can't edit them there, \
        so changes and deletions also go through you.

        ## Style
        - One to three SHORT sentences per reply, casual and conversational. No headers, no \
        preamble, no recap of what the user asked. Speed beats thoroughness: give the quick answer \
        now and let a task do the thorough version. EVERY URL or page you mention must be a \
        markdown link (`[title](url)`) — never a bare URL; clicking a link in this thread opens it \
        as a tab. The same goes for notes you write and for anything you relay from a task.
        - Don't narrate tool calls. Don't ask permission for routine actions like opening a page.
        - Always end your turn promptly after dispatching work.
        \(folder.map { "\n## Space folder\nThis space is attached to the folder `\($0)` — use it as the default cwd/workingDirectory for terminals and coding tasks." } ?? "")
        """
    }
}
