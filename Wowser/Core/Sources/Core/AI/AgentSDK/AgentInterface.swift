import Foundation

// A minimal, harness-agnostic interface for conversational agents that can use
// tools and see images. `ClaudeCodeAgent` (backed by the `claude` CLI) is the
// first implementation; other harnesses can conform without touching callers.

// MARK: - Messages in / results out

/// A user-authored message sent to an agent: text plus optional images.
/// Reuses `BrowserJSImage` ({mime, base64 data}) so BJS screenshots flow
/// straight into agent input.
public struct AgentUserMessage: Sendable {
    public var text: String
    public var images: [BrowserJSImage]

    public init(text: String, images: [BrowserJSImage] = []) {
        self.text = text
        self.images = images
    }
}

/// The outcome of one agent turn (a user message and everything the agent did
/// in response, through to its final reply).
public struct AgentTurnResult: Sendable, Codable {
    public var text: String
    public var isError: Bool
    public var stopReason: String?
    public var costUSD: Double?
    public var sessionID: String?

    public init(text: String, isError: Bool = false, stopReason: String? = nil, costUSD: Double? = nil, sessionID: String? = nil) {
        self.text = text; self.isError = isError; self.stopReason = stopReason
        self.costUSD = costUSD; self.sessionID = sessionID
    }
}

// MARK: - Tools

/// The result a tool handler returns to the agent. Images are passed through so
/// the agent can *see* content the tool captured (e.g. BJS screenshots).
public struct AgentToolOutput: Sendable {
    public var text: String
    public var images: [BrowserJSImage]
    public var isError: Bool

    public init(text: String, images: [BrowserJSImage] = [], isError: Bool = false) {
        self.text = text; self.images = images; self.isError = isError
    }
}

/// A host-implemented tool exposed to the agent. `inputSchemaJSON` is a JSON
/// Schema object as a string; the handler receives the tool input as a JSON
/// object string.
public struct AgentToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public var handler: @Sendable (_ inputJSON: String) async -> AgentToolOutput

    public init(name: String, description: String, inputSchemaJSON: String, handler: @escaping @Sendable (String) async -> AgentToolOutput) {
        self.name = name; self.description = description
        self.inputSchemaJSON = inputSchemaJSON; self.handler = handler
    }
}

// MARK: - Events

/// Events an agent emits while working. Observe via `Agent.events()`.
public enum AgentEvent: Sendable {
    case started(sessionID: String)
    /// A completed assistant text block.
    case assistantText(String)
    /// A completed assistant thinking block (may be empty depending on model).
    case thinking(String)
    case toolUse(name: String, inputJSON: String)
    case toolResult(text: String, isError: Bool)
    case turnCompleted(AgentTurnResult)
    case failed(String)
    case terminated
}

// MARK: - Creating agents

/// Harness-agnostic parameters for creating an agent.
public struct AgentSpec: Sendable {
    /// Model name or alias ("opus" | "sonnet" | "haiku" | "fable" | full id).
    /// nil = the harness's default.
    public var model: String?
    /// Reasoning effort: "low" | "medium" | "high" (harnesses may accept more).
    public var effort: String?
    public var systemPrompt: String?
    public var appendSystemPrompt: String?
    /// Host tools exposed to the agent.
    public var tools: [AgentToolDefinition]

    public init(model: String? = nil, effort: String? = nil, systemPrompt: String? = nil, appendSystemPrompt: String? = nil, tools: [AgentToolDefinition] = []) {
        self.model = model; self.effort = effort
        self.systemPrompt = systemPrompt; self.appendSystemPrompt = appendSystemPrompt
        self.tools = tools
    }
}

/// A factory for a particular agent harness. Register one with
/// `BrowserAgentManager` to make agents creatable on this platform.
public protocol AgentProvider: Sendable {
    /// Short identifier, e.g. "claude-code".
    var id: String { get }
    /// Whether this provider can actually create agents right now
    /// (e.g. the backing CLI is installed).
    var isAvailable: Bool { get }
    func makeAgent(_ spec: AgentSpec) -> any Agent
}

// MARK: - The protocol

/// A conversational, tool-using agent session. Implementations own their
/// harness (CLI subprocess, HTTP API, in-process loop, ...).
public protocol Agent: AnyObject, Sendable {
    /// Send a user message and wait for the agent's turn to complete.
    /// Turns are serialized: concurrent sends queue in order.
    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult

    /// A stream of events for this agent, starting from subscription time.
    /// Multiple subscribers are supported.
    func events() async -> AsyncStream<AgentEvent>

    /// Ask the agent to stop what it's doing (the current turn ends early).
    func interrupt() async

    /// Tear down the agent and its resources. The agent is unusable afterwards.
    func shutdown() async
}

public enum AgentSDKError: LocalizedError {
    case binaryNotFound
    case notRunning
    case turnFailed(String)
    case timeout
    case shutDown
    case noProviderAvailable

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "claude CLI binary not found — install Claude Code or set an explicit path"
        case .notRunning: return "agent process is not running"
        case .turnFailed(let msg): return "agent turn failed: \(msg)"
        case .timeout: return "agent turn timed out"
        case .shutDown: return "agent has been shut down"
        case .noProviderAvailable: return "no agent implementation is available on this platform"
        }
    }
}
