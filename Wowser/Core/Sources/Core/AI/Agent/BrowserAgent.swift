import Foundation
import Combine
import ChatToys

// Data stored on a Tab that represents an agent session.
// Agent tabs that are 'attached to the input box' additionally live under BrowserState.hiddenAgentTabs
// (a hidden parent) rather than in any sidebar list.
public struct AgentTabInfo: Equatable, Codable {
    public var instructions: String
    public var status: Status
    public var statusText: String?
    public var attachedToWindow: ID<WindowState>?
    public var startedAt: Date

    public enum Status: String, Equatable, Codable {
        case working
        case done
        case error
    }

    public init(instructions: String, status: Status = .working, statusText: String? = nil, attachedToWindow: ID<WindowState>? = nil, startedAt: Date = Date()) {
        self.instructions = instructions
        self.status = status
        self.statusText = statusText
        self.attachedToWindow = attachedToWindow
        self.startedAt = startedAt
    }
}

// Manages live agent sessions (keyed by their agent tab), similar to how BrowserStore manages WebContents
class BrowserAgentManager {
    static let shared = BrowserAgentManager()

    enum Source: Equatable {
        case userInstruction(dictated: Bool)
        case scheduledTask
    }

    private(set) var sessions = [ID<Tab>: BrowserAgentSession]()
    private var subscriptions = Set<AnyCancellable>()

    init() {
        // Drop (and cancel) sessions whose tabs no longer exist
        BrowserStore.shared.uiPublisher
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .map { state in Set(state.tabs.keys) }
            .removeDuplicates()
            .sink { [weak self] tabIds in
                guard let self else { return }
                for (tabId, session) in self.sessions where !tabIds.contains(tabId) {
                    session.cancel()
                    self.sessions.removeValue(forKey: tabId)
                }
            }
            .store(in: &subscriptions)
    }

    @discardableResult
    func startSession(instructions: String, source: Source, windowID: ID<WindowState>?) -> ID<Tab>? {
        assertOnMainThread()
        let store = BrowserStore.shared
        let windowID = windowID ?? store.model.activeWindow?.id
        let profileID = windowID.flatMap { store.model.windows[$0]?.profile }

        var info = WebContent.Info()
        info.title = Self.tabTitle(forInstructions: instructions)
        var tab = Tab(id: .assign(), panes: [Pane(id: .assign(), info: info)])
        tab.agentInfo = AgentTabInfo(instructions: instructions, attachedToWindow: windowID)

        store.modify { state in
            state.insertHiddenAgentTab(tab)
        }

        let session = BrowserAgentSession(tabID: tab.id, instructions: instructions, source: source, windowID: windowID, profileID: profileID)
        sessions[tab.id] = session
        session.start()
        return tab.id
    }

    func session(forTab id: ID<Tab>) -> BrowserAgentSession? {
        sessions[id]
    }

    // Called when the user clicks the 'agent is working' indicator in the input box
    func revealMostRecentAttachedTab(inWindow windowID: ID<WindowState>) {
        assertOnMainThread()
        BrowserStore.shared.modify { state in
            if let tab = state.agentTabsAttached(toWindow: windowID).last {
                state.revealAgentTab(id: tab.id, inWindow: windowID)
            }
        }
    }

    private static func tabTitle(forInstructions instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Agent: " + trimmed.truncateTailWithEllipsis(chars: 40)
    }
}

// A live agent session. The session's tab is the source of truth for its existence;
// the thread model (transcript) lives here and is not persisted.
class BrowserAgentSession: ObservableObject, Identifiable, AgentThreadStore {
    let tabID: ID<Tab>
    let instructions: String
    let source: BrowserAgentManager.Source
    let windowID: ID<WindowState>?
    let profileID: ID<Profile>?

    @Published var thread = ThreadModel()
    private var runTask: Task<Void, Never>?

    var id: String { tabID.raw }

    init(tabID: ID<Tab>, instructions: String, source: BrowserAgentManager.Source, windowID: ID<WindowState>?, profileID: ID<Profile>?) {
        self.tabID = tabID
        self.instructions = instructions
        self.source = source
        self.windowID = windowID
        self.profileID = profileID
    }

    func start() {
        runTask = Task { @MainActor [self] in
            do {
                let llm = try LLMs.currentOrThrow_fnCalling()
                let tool = BrowserControlTool(session: self)
                var messageParts = [ContextItem]()
                if case .userInstruction(dictated: true) = self.source {
                    messageParts.append(.systemInstruction("The instruction below was dictated by voice. The transcription may contain errors or filler words; interpret what the user most likely meant."))
                }
                if case .scheduledTask = self.source {
                    messageParts.append(.systemInstruction("This is a scheduled task that runs automatically on a cadence the user chose. Perform it without asking for input."))
                }
                messageParts.append(.text(self.instructions))
                try await self.send(
                    message: TaggedLLMMessage(role: .user, content: messageParts),
                    llm: llm,
                    tools: [tool],
                    systemPrompt: Self.systemPrompt,
                    agentName: "BrowserAgent",
                    profileId: self.profileID
                )
                self.handleCompletion(error: nil)
            } catch {
                if !(error is CancellationError) {
                    self.handleCompletion(error: error)
                }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    // Called by tools (or on error) when the agent needs to surface itself as a real tab
    func revealTab() {
        assertOnMainThread()
        BrowserStore.shared.modify { state in
            guard state.hiddenAgentTabIds.contains(self.tabID) else { return }
            let winID = state.tabs[self.tabID]?.agentInfo?.attachedToWindow ?? state.activeWindow?.id
            if let winID, state.windows[winID] != nil {
                state.revealAgentTab(id: self.tabID, inWindow: winID)
            }
        }
    }

    private func handleCompletion(error: Error?) {
        assertOnMainThread()
        let tabID = self.tabID
        let store = BrowserStore.shared
        if let error {
            store.modify { state in
                state.modifyTab(id: tabID) { tab in
                    tab.agentInfo?.status = .error
                    tab.agentInfo?.statusText = "\(error)"
                }
            }
            // Errors pop the agent up as a real tab so the user can see what happened
            revealTab()
        } else if store.model.hiddenAgentTabIds.contains(tabID) {
            // Finished without ever needing the user; close silently
            store.modify { state in
                state.removeHiddenAgentTab(id: tabID)
            }
        } else {
            store.modify { state in
                state.modifyTab(id: tabID) { tab in
                    tab.agentInfo?.status = .done
                }
            }
        }
    }

    // MARK: - AgentThreadStore

    func readThreadModel() async -> ThreadModel {
        await MainActor.run { thread }
    }

    func modifyThreadModel<ReturnVal>(_ callback: @escaping (inout ThreadModel) -> ReturnVal) async -> ReturnVal {
        await MainActor.run {
            callback(&thread)
        }
    }

    func threadModelPublisher() -> AnyPublisher<ThreadModel, Never> {
        $thread.eraseToAnyPublisher()
    }

    static let systemPrompt = """
    You are a browser automation agent inside Wowser, a webkit-based browser. You run headlessly in the background, attached to the browser's input box, and can read and modify the state of the browser using your tools.

    Guidelines:
    - Work silently. The user should not be interrupted while you work.
    - Only call show_to_user if you genuinely need the user's attention — for example, you have a result they must look at, or you hit a problem you cannot resolve on your own.
    - When the task is complete, stop calling tools and reply with a one or two sentence summary of what you did. If you never revealed yourself, your tab will close automatically.

    [[CONTEXT]]
    """
}
