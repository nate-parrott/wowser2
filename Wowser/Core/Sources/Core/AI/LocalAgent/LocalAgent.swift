import Foundation
import FoundationModels

// An `Agent` driven by Apple's on-device model. Much simpler than the Claude
// Code agent: no BrowserJS, just three native tools (navigate, ask_page,
// web_research — see LocalAgentTools.swift). It ignores the spec's prompt and
// tools, since those are written for Claude.
//
// The model's window is ~4K tokens, so every token counts: the instructions
// are terse, each user message gets a one-line ambient prefix (date + the page
// the user is looking at), and once the transcript nears `compactAtTokens`
// the model is asked to summarize the conversation, which seeds a fresh
// session.

/// Which implementation runs chat/ask agents. Settings → AI.
public enum AgentHarness: String, CaseIterable {
    case claude
    case local

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .local: return "On device"
        }
    }

    static var current: AgentHarness {
        AgentHarness(rawValue: DefaultsKeys.agentHarness.stringValue()) ?? .claude
    }

    /// Value for `BrowserJSAgentCreateOptions.harness`.
    var createOptionsValue: String? {
        self == .local ? LocalAgentProvider.harnessID : nil
    }
}

struct LocalAgentProvider: AgentProvider {
    static let harnessID = "local"

    /// Agent session key — used to find the page the user is looking at.
    var key: String

    var id: String { Self.harnessID }
    var isAvailable: Bool { MicroAI.onDeviceAvailable }

    func makeAgent(_ spec: AgentSpec) -> any Agent {
        LocalAgent(key: key)
    }
}

actor LocalAgent: Agent {
    private let key: String
    private let sessionID = UUID().uuidString
    private var session: LanguageModelSession?
    /// What earlier (compacted) parts of the conversation said.
    private var summary: String?
    private var subscribers: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var tail: Task<Void, Never>?
    private var turns: [UUID: Task<AgentTurnResult, Error>] = [:]
    private var activeTurn: UUID?
    private var isShutDown = false

    /// Compact when the transcript is estimated past this (window is ~4K).
    private let compactAtTokens = 3000

    init(key: String) {
        self.key = key
    }

    // MARK: Agent

    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
        guard !isShutDown else { throw AgentSDKError.shutDown }
        let id = UUID()
        let previous = tail
        let turn = Task { () async throws -> AgentTurnResult in
            await previous?.value
            return try await self.runTurn(id: id, message)
        }
        turns[id] = turn
        tail = Task { _ = try? await turn.value }
        defer { turns[id] = nil }
        return try await turn.value
    }

    func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func interrupt() {
        if let activeTurn { turns[activeTurn]?.cancel() }
    }

    func shutdown() {
        isShutDown = true
        for turn in turns.values { turn.cancel() }
        emit(.terminated)
        for c in subscribers.values { c.finish() }
        subscribers = [:]
    }

    // MARK: Turns

    private func runTurn(id: UUID, _ message: AgentUserMessage) async throws -> AgentTurnResult {
        guard !isShutDown else { throw AgentSDKError.shutDown }
        activeTurn = id
        defer { activeTurn = nil }
        if session == nil {
            emit(.started(sessionID: sessionID))
        }
        let ambient = await LocalAgentContext.ambient(key: key)
        var text = message.text
        if !message.images.isEmpty { text += "\n[\(message.images.count) image(s) omitted — you can't see images]" }
        let prompt = ambient + "\n" + text

        let logID = AIRequestLog.shared.begin(modelName: "On device - Agent")
        do {
            if estimatedTokens > compactAtTokens { try await compact() }
            let reply: String
            do {
                reply = try await currentSession().respond(to: prompt).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // Overflowed mid-turn (e.g. big tool results): start over from
                // the summary we have and retry once.
                session = nil
                reply = try await currentSession().respond(to: prompt).content
            }
            AIRequestLog.shared.finish(id: logID, error: nil)
            emit(.assistantText(reply))
            let result = AgentTurnResult(text: reply, sessionID: sessionID)
            emit(.turnCompleted(result))
            return result
        } catch is CancellationError {
            AIRequestLog.shared.finish(id: logID, error: nil)
            // A cancelled respond leaves the session unusable mid-turn.
            session = nil
            emit(.interrupted)
            let result = AgentTurnResult(text: "", stopReason: "interrupted", sessionID: sessionID)
            emit(.turnCompleted(result))
            return result
        } catch {
            AIRequestLog.shared.finish(id: logID, error: error)
            session = nil
            let result = AgentTurnResult(text: error.localizedDescription, isError: true, sessionID: sessionID)
            emit(.turnCompleted(result))
            return result
        }
    }

    private func currentSession() throws -> LanguageModelSession {
        if let session { return session }
        guard MicroAI.onDeviceAvailable else { throw MicroAIError.unavailable(.onDevice) }
        let key = self.key
        let log: @Sendable (AgentEvent) async -> Void = { [weak self] event in await self?.emit(event) }
        let tools: [any FoundationModels.Tool] = [
            NavigateTool(key: key, log: log),
            AskPageTool(key: key, log: log),
            WebResearchLocalTool(log: log),
        ]
        var instructions = """
        You are the assistant built into the user's web browser, running on their device. \
        Be brief and direct. Each user message starts with [context]: the date and the page the user is looking at. \
        Use ask_page for questions about that page, web_research for facts you don't know or that may have changed, \
        and navigate to open a site. Otherwise answer directly.
        """
        if let summary {
            instructions += "\n\nEarlier in this conversation: " + summary
        }
        let session = LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        self.session = session
        return session
    }

    /// Asks the model to summarize the conversation so far, then continues in
    /// a fresh session seeded with that summary.
    private func compact() async throws {
        guard let session else { return }
        let reply = try await session.respond(
            to: "Summarize our conversation so far in under 100 words: what the user wants, key facts found, anything unfinished. Output only the summary.",
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
        )
        summary = reply.content
        self.session = nil
    }

    /// Rough token count of the live transcript (~3.5 chars/token), plus tool
    /// definitions, which don't appear in the transcript's text.
    private var estimatedTokens: Int {
        guard let session else { return 0 }
        let chars = session.transcript.reduce(0) { $0 + $1.description.count }
        return chars * 2 / 7 + 250
    }

    // MARK: Events

    private func emit(_ event: AgentEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
