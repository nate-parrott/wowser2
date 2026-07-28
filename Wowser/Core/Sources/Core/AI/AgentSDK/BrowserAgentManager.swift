import Foundation

// Bridges `Agent` instances into the BrowserJS world: BJS creates/manages
// agents via `browser.agent.*`, and each agent optionally gets a
// `run_browser_js` tool (with the BrowserJS docs injected into its system
// prompt) so it can drive the browser itself.
//
// The manager is platform-neutral: it stores `any Agent` and creates them
// through a pluggable `AgentProvider`. Only `create` fails on platforms with
// no registered provider (e.g. iOS today).

// MARK: - BJS-facing value types

public struct BrowserJSAgentCreateOptions: Codable, Sendable {
    public var name: String?
    /// "opus" | "sonnet" | "haiku" | "fable" | a full model id. nil = default.
    public var model: String?
    /// "low" | "medium" | "high". nil = default.
    public var effort: String?
    public var systemPrompt: String?
    /// When true (default), the agent gets a `run_browser_js` tool and the
    /// BrowserJS .d.ts docs in its system prompt.
    public var exposeBrowserJS: Bool

    public init(name: String? = nil, model: String? = nil, effort: String? = nil, systemPrompt: String? = nil, exposeBrowserJS: Bool = true) {
        self.name = name; self.model = model; self.effort = effort
        self.systemPrompt = systemPrompt; self.exposeBrowserJS = exposeBrowserJS
    }
}

public struct BrowserJSAgentInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var model: String?
    /// "idle" | "running" | "disposed"
    public var status: String
    public var messageCount: Int

    public init(id: String, name: String? = nil, model: String? = nil, status: String, messageCount: Int) {
        self.id = id; self.name = name; self.model = model
        self.status = status; self.messageCount = messageCount
    }
}

public struct BrowserJSAgentMessage: Codable, Equatable, Sendable {
    public var index: Int
    /// "user" | "assistant" | "thinking" | "tool_use" | "tool_result" | "error"
    public var role: String
    public var text: String
    public var toolName: String?

    public init(index: Int, role: String, text: String, toolName: String? = nil) {
        self.index = index; self.role = role; self.text = text; self.toolName = toolName
    }
}

public struct BrowserJSAgentAwaitResult: Codable, Equatable, Sendable {
    /// True when the agent is idle (the awaited turn finished or none was running).
    public var done: Bool
    public var status: String
    /// The final text of the last completed turn, when done.
    public var text: String?
    public var isError: Bool

    public init(done: Bool, status: String, text: String? = nil, isError: Bool = false) {
        self.done = done; self.status = status; self.text = text; self.isError = isError
    }
}

// MARK: - Manager

public actor BrowserAgentManager {
    public static let shared = BrowserAgentManager(
        provider: BrowserAgentManager.platformDefaultProvider(),
        host: BrowserJSLiveHost.shared,
        helpers: BrowserJSHelpers.shared
    )

    static func platformDefaultProvider() -> (any AgentProvider)? {
        #if os(macOS)
        return ClaudeCodeAgentProvider()
        #else
        return nil
        #endif
    }

    private struct Entry {
        var agent: any Agent
        var name: String?
        var model: String?
        var status: String  // "idle" | "running" | "disposed"
        var messages: [BrowserJSAgentMessage] = []
        var lastResult: AgentTurnResult?
        var eventTask: Task<Void, Never>?
    }

    private var provider: (any AgentProvider)?
    private let host: any BrowserJSHost
    private let helpers: BrowserJSHelpersProvider
    private var runtime: BrowserJSRuntime?
    private var entries: [String: Entry] = [:]
    private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(provider: (any AgentProvider)?, host: any BrowserJSHost, helpers: BrowserJSHelpersProvider) {
        self.provider = provider
        self.host = host
        self.helpers = helpers
    }

    /// Swap the agent implementation (e.g. a future iOS-compatible harness,
    /// or a fake in tests).
    public func setProvider(_ provider: (any AgentProvider)?) {
        self.provider = provider
    }

    // MARK: - Operations (BJS surface)

    public func create(options: BrowserJSAgentCreateOptions) async throws -> String {
        guard let provider, provider.isAvailable else {
            throw BrowserJSError.underlying(AgentSDKError.noProviderAvailable.localizedDescription)
        }
        let id = "agent-" + UUID().uuidString.lowercased().prefix(8)
        var spec = AgentSpec(
            model: options.model,
            effort: options.effort,
            systemPrompt: options.systemPrompt
        )
        if options.exposeBrowserJS {
            spec.tools.append(makeRunBrowserJSTool())
            spec.appendSystemPrompt = """
            ## Browser control

            You are running inside the Wowser browser and can drive it with the \
            `run_browser_js` tool. Your code runs as the body of an async \
            function with a global `browser` object — use top-level `await` and \
            `return <expr>` to produce a result. To see a page, call \
            `browser.viewImage(await browser.content.screenshot(tabId))`; the \
            screenshot comes back to you as an image.

            The full BrowserJS API (TypeScript declarations):

            ```typescript
            \(BrowserJSDocs.dts)
            ```
            """
        }
        let agent = provider.makeAgent(spec)
        var entry = Entry(agent: agent, name: options.name, model: options.model, status: "idle")
        // Subscribe before returning so no early events are missed.
        let eventStream = await agent.events()
        entry.eventTask = Task { [weak self] in
            for await event in eventStream {
                await self?.handleEvent(event, agentID: String(id))
            }
        }
        entries[String(id)] = entry
        return String(id)
    }

    /// Starts a turn. Returns immediately; observe via messages()/awaitIdle().
    public func send(id: String, text: String, images: [BrowserJSImage]) async throws {
        guard var entry = entries[id], entry.status != "disposed" else {
            throw BrowserJSError.invalidArgs("unknown agent: \(id)")
        }
        entry.status = "running"
        entry.messages.append(BrowserJSAgentMessage(
            index: entry.messages.count, role: "user",
            text: text + (images.isEmpty ? "" : " [\(images.count) image(s)]")
        ))
        let agent = entry.agent
        entries[id] = entry
        Task {
            _ = try? await agent.send(AgentUserMessage(text: text, images: images))
        }
    }

    /// Waits until the agent is idle, up to `timeoutMs`. Never throws on
    /// timeout — returns `done: false` so callers can re-await.
    public func awaitIdle(id: String, timeoutMs: Int) async throws -> BrowserJSAgentAwaitResult {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        if entry.status != "running" {
            return snapshotResult(entry)
        }
        _ = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { [weak self] in
                await withCheckedContinuation { c in
                    Task { await self?.addIdleWaiter(id: id, continuation: c) }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard let latest = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        return snapshotResult(latest)
    }

    public func messages(id: String, since: Int) throws -> [BrowserJSAgentMessage] {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        return entry.messages.filter { $0.index >= since }
    }

    public func list() -> [BrowserJSAgentInfo] {
        entries.map { id, e in
            BrowserJSAgentInfo(id: id, name: e.name, model: e.model, status: e.status, messageCount: e.messages.count)
        }.sorted { $0.id < $1.id }
    }

    public func interrupt(id: String) async throws {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        await entry.agent.interrupt()
    }

    public func dispose(id: String) async throws {
        guard var entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        entry.status = "disposed"
        entry.eventTask?.cancel()
        entries[id] = entry
        resumeIdleWaiters(id: id)
        await entry.agent.shutdown()
    }

    // MARK: - Internals

    private func snapshotResult(_ entry: Entry) -> BrowserJSAgentAwaitResult {
        BrowserJSAgentAwaitResult(
            done: entry.status != "running",
            status: entry.status,
            text: entry.lastResult?.text,
            isError: entry.lastResult?.isError ?? false
        )
    }

    private func addIdleWaiter(id: String, continuation: CheckedContinuation<Void, Never>) {
        // Re-check: the turn may have finished between the caller's check and now.
        if entries[id]?.status != "running" {
            continuation.resume()
            return
        }
        idleWaiters[id, default: []].append(continuation)
    }

    private func resumeIdleWaiters(id: String) {
        for c in idleWaiters[id] ?? [] { c.resume() }
        idleWaiters[id] = nil
    }

    private func handleEvent(_ event: AgentEvent, agentID: String) {
        guard var entry = entries[agentID], entry.status != "disposed" else { return }
        func append(role: String, text: String, toolName: String? = nil) {
            entry.messages.append(BrowserJSAgentMessage(
                index: entry.messages.count, role: role,
                text: String(text.prefix(20_000)), toolName: toolName
            ))
        }
        switch event {
        case .assistantText(let text):
            append(role: "assistant", text: text)
        case .thinking(let text):
            if !text.isEmpty { append(role: "thinking", text: text) }
        case .toolUse(let name, let inputJSON):
            append(role: "tool_use", text: inputJSON, toolName: name)
        case .toolResult(let text, let isError):
            append(role: "tool_result", text: isError ? "[error] \(text)" : text)
        case .turnCompleted(let result):
            entry.status = "idle"
            entry.lastResult = result
            if result.isError { append(role: "error", text: result.text) }
            entries[agentID] = entry
            resumeIdleWaiters(id: agentID)
            return
        case .failed(let message):
            entry.status = "idle"
            entry.lastResult = AgentTurnResult(text: message, isError: true)
            append(role: "error", text: message)
            entries[agentID] = entry
            resumeIdleWaiters(id: agentID)
            return
        case .started, .terminated:
            break
        }
        entries[agentID] = entry
    }

    private func makeRunBrowserJSTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "run_browser_js",
            description: """
            Run JS in the browser's privileged BrowserJS environment (a global \
            `browser` object; see the BrowserJS docs in your system prompt). \
            Your code is the body of an async function: use top-level `await` \
            and `return <expr>` to produce a result. Call \
            `browser.viewImage(await browser.content.screenshot(tabId))` to see \
            a screenshot — it is attached to the tool result as an image.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"code":{"type":"string","description":"BrowserJS source. May use top-level await."}},"required":["code"]}"#
        ) { [weak self] inputJSON in
            guard let self else { return AgentToolOutput(text: "browser unavailable", isError: true) }
            let code = ((try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any])?["code"] as? String
            guard let code else { return AgentToolOutput(text: "missing `code` argument", isError: true) }
            let result = await self.runBrowserJS(code: code)
            var payload: [String: Any] = ["logs": result.logs]
            if let r = result.result { payload["result"] = r }
            if let e = result.error { payload["error"] = e }
            if result.truncated { payload["truncated"] = true }
            let text = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return AgentToolOutput(
                text: text,
                images: result.images.filter { !$0.data.isEmpty },
                isError: result.error != nil
            )
        }
    }

    private func runBrowserJS(code: String) async -> BrowserJSResult {
        let runtime: BrowserJSRuntime
        if let existing = self.runtime {
            runtime = existing
        } else {
            runtime = BrowserJSRuntime(host: host, helpers: helpers)
            self.runtime = runtime
        }
        return await runtime.run(code: code)
    }
}
