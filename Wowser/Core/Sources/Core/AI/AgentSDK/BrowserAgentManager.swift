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

/// A tool an app implements in JavaScript and hands to its agent. The agent
/// calls it; the call surfaces through `agent.await` and the app answers with
/// `agent.respondTool`. `browser.agent.serve()` wires that up as plain
/// callbacks.
public struct BrowserJSAgentToolSpec: Codable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema for the tool's arguments, as a JSON string.
    public var inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name; self.description = description; self.inputSchemaJSON = inputSchemaJSON
    }
}

/// An agent's pending call into app-provided JS. Answer it with `respondTool`.
public struct BrowserJSAgentToolCall: Codable, Equatable, Sendable {
    public var callId: String
    public var name: String
    /// The agent's arguments, as a JSON object string.
    public var inputJSON: String

    public init(callId: String, name: String, inputJSON: String) {
        self.callId = callId; self.name = name; self.inputJSON = inputJSON
    }
}

public struct BrowserJSAgentCreateOptions: Codable, Sendable {
    /// A stable name for a long-running session. Creating with the same key
    /// returns the SAME agent — reconnecting to the live one if it's still
    /// around, otherwise resuming it from disk (conversation and transcript
    /// intact) across page reloads and app restarts. Omit for a throwaway
    /// agent that dies with the process.
    public var key: String?
    public var name: String?
    /// "opus" | "sonnet" | "haiku" | "fable" | a full model id. nil = default.
    public var model: String?
    /// "low" | "medium" | "high". nil = default.
    public var effort: String?
    public var systemPrompt: String?
    /// When true (default), the agent gets a `run_browser_js` tool and the
    /// BrowserJS .d.ts docs in its system prompt.
    public var exposeBrowserJS: Bool
    /// When true, the agent also gets real filesystem/shell tools scoped to
    /// `workingDirectory`. Off by default.
    public var fileSystemTools: Bool
    /// Directory for the filesystem tools. Ignored unless `fileSystemTools`.
    public var workingDirectory: String?
    /// Tools the app implements itself, in JS.
    public var tools: [BrowserJSAgentToolSpec]

    public init(key: String? = nil, name: String? = nil, model: String? = nil, effort: String? = nil, systemPrompt: String? = nil, exposeBrowserJS: Bool = true, fileSystemTools: Bool = false, workingDirectory: String? = nil, tools: [BrowserJSAgentToolSpec] = []) {
        self.key = key; self.name = name; self.model = model; self.effort = effort
        self.systemPrompt = systemPrompt; self.exposeBrowserJS = exposeBrowserJS
        self.fileSystemTools = fileSystemTools; self.workingDirectory = workingDirectory
        self.tools = tools
    }
}

public struct BrowserJSAgentInfo: Codable, Equatable, Sendable {
    public var id: String
    /// The stable key, for agents created with one.
    public var key: String?
    public var name: String?
    public var model: String?
    /// "idle" | "running" | "disposed" | "saved" (persisted, not currently loaded)
    public var status: String
    public var messageCount: Int

    public init(id: String, key: String? = nil, name: String? = nil, model: String? = nil, status: String, messageCount: Int) {
        self.id = id; self.key = key; self.name = name; self.model = model
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
    /// Transcript entries added since the `since` index the caller passed —
    /// delivered as they happen (assistant text, tool calls, tool results),
    /// so a UI can render progress mid-turn instead of only at the end.
    public var messages: [BrowserJSAgentMessage]
    /// Pass this back as `since` on the next call.
    public var nextIndex: Int
    /// App-implemented tools the agent is waiting on. Run them and answer with
    /// `agent.respondTool` — the agent is blocked until you do. Each call is
    /// handed out once.
    public var toolCalls: [BrowserJSAgentToolCall]

    public init(done: Bool, status: String, text: String? = nil, isError: Bool = false, messages: [BrowserJSAgentMessage] = [], nextIndex: Int = 0, toolCalls: [BrowserJSAgentToolCall] = []) {
        self.done = done; self.status = status; self.text = text; self.isError = isError
        self.messages = messages; self.nextIndex = nextIndex; self.toolCalls = toolCalls
    }
}

// MARK: - Manager

public actor BrowserAgentManager {
    public static let shared = BrowserAgentManager(
        provider: BrowserAgentManager.platformDefaultProvider(),
        host: BrowserJSLiveHost.shared,
        helpers: BrowserJSHelpers.shared,
        store: AgentSessionStore.shared
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
        var key: String?
        var name: String?
        var model: String?
        var status: String  // "idle" | "running" | "disposed"
        var messages: [BrowserJSAgentMessage] = []
        var lastResult: AgentTurnResult?
        var eventTask: Task<Void, Never>?
        /// Harness session id, learned from `.started` — what we resume from.
        var sessionID: String?
        /// Persisted config, so a resumed agent comes back the same way.
        var record: AgentSessionRecord?
    }

    private var provider: (any AgentProvider)?
    private let host: any BrowserJSHost
    private let helpers: BrowserJSHelpersProvider
    private let store: any AgentSessionStoring
    private var runtime: BrowserJSRuntime?
    private var entries: [String: Entry] = [:]
    private var keyToAgentID: [String: String] = [:]
    private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// An agent's call into app-provided JS, parked until the app answers.
    private struct ParkedToolCall {
        let call: BrowserJSAgentToolCall
        let agentID: String
        var handedOut = false
        var continuation: CheckedContinuation<AgentToolOutput, Never>?
        var timeoutTask: Task<Void, Never>?
    }
    private var parkedToolCalls: [String: ParkedToolCall] = [:]
    /// How long an app has to answer a tool call before the agent is told it failed.
    private let appToolTimeout: TimeInterval = 120

    public init(provider: (any AgentProvider)?, host: any BrowserJSHost, helpers: BrowserJSHelpersProvider, store: any AgentSessionStoring = AgentSessionStore.shared) {
        self.provider = provider
        self.host = host
        self.helpers = helpers
        self.store = store
    }

    /// Swap the agent implementation (e.g. a future iOS-compatible harness,
    /// or a fake in tests).
    public func setProvider(_ provider: (any AgentProvider)?) {
        self.provider = provider
    }

    /// Feature-supplied native tools, resolved by session key whenever an agent
    /// starts (including resume-from-disk). Lets app features (e.g. agent chat
    /// tabs) give their agents Swift-implemented tools that survive resume —
    /// unlike `appTools`, which are answered by JS.
    private var nativeToolProvider: (@Sendable (_ key: String) -> [AgentToolDefinition])?
    public func setNativeToolProvider(_ provider: @escaping @Sendable (_ key: String) -> [AgentToolDefinition]) {
        self.nativeToolProvider = provider
    }

    // MARK: - Operations (BJS surface)

    public func create(options: BrowserJSAgentCreateOptions) async throws -> String {
        // A keyed agent is a long-running session: reconnect to the live one
        // if it's still loaded, otherwise resume it from disk.
        if let key = options.key {
            if let existingID = keyToAgentID[key], entries[existingID]?.status != "disposed" {
                return existingID
            }
            if let record = store.load(key: key) {
                return try await resume(record)
            }
        }
        guard let provider, provider.isAvailable else {
            throw BrowserJSError.underlying(AgentSDKError.noProviderAvailable.localizedDescription)
        }
        let id = "agent-" + String(UUID().uuidString.lowercased().prefix(8))
        var record = AgentSessionRecord(
            key: options.key ?? id,
            agentID: id,
            name: options.name,
            model: options.model,
            effort: options.effort,
            systemPrompt: options.systemPrompt,
            exposeBrowserJS: options.exposeBrowserJS,
            fileSystemTools: options.fileSystemTools,
            workingDirectory: options.workingDirectory,
            appTools: options.tools
        )
        record.sessionID = nil
        try await start(record: record, isKeyed: options.key != nil)
        return id
    }

    /// Reload a persisted agent: same id, same config, and the harness told to
    /// resume its session so the agent still remembers the conversation. The
    /// transcript starts empty — old messages are never replayed.
    private func resume(_ record: AgentSessionRecord) async throws -> String {
        try await start(record: record, isKeyed: true)
        return record.agentID
    }

    private func start(record: AgentSessionRecord, isKeyed: Bool) async throws {
        guard let provider, provider.isAvailable else {
            throw BrowserJSError.underlying(AgentSDKError.noProviderAvailable.localizedDescription)
        }
        var spec = AgentSpec(
            model: record.model,
            effort: record.effort,
            systemPrompt: record.systemPrompt,
            enableFileSystemTools: record.fileSystemTools,
            workingDirectory: record.workingDirectory.map { URL(fileURLWithPath: $0) },
            resumeSessionID: record.sessionID
        )
        if record.exposeBrowserJS {
            spec.tools.append(makeRunBrowserJSTool())
            spec.appendSystemPrompt = """
            ## Browser control

            You are running inside the Wowser browser and can drive it with the \
            `run_browser_js` tool. Your code runs as the body of an async \
            function with a global `browser` object — use top-level `await` and \
            `return <expr>` to produce a result. To see a page, call \
            `browser.viewImage(await browser.content.screenshot(tabId))`; the \
            screenshot comes back to you as an image.

            Work in the background by default: the user is using this browser \
            while you work. Open pages with `browser.tabs.openGhost(url)` — a \
            hidden agent tab on which read, screenshot, click, type, key and \
            eval all work — rather than `tabs.open`, unless the user asked to \
            see the page. Close ghost tabs when you're done with them.

            The full BrowserJS API (TypeScript declarations):

            ```typescript
            \(BrowserJSDocs.dts)
            ```
            """
        }
        let id = record.agentID
        for tool in record.appTools {
            spec.tools.append(makeAppTool(tool, agentID: id))
        }
        if let nativeToolProvider {
            spec.tools.append(contentsOf: nativeToolProvider(record.key))
        }
        let agent = provider.makeAgent(spec)
        var entry = Entry(
            agent: agent,
            key: isKeyed ? record.key : nil,
            name: record.name,
            model: record.model,
            status: "idle"
        )
        entry.sessionID = record.sessionID
        entry.record = isKeyed ? record : nil
        // Subscribe before returning so no early events are missed.
        let eventStream = await agent.events()
        entry.eventTask = Task { [weak self] in
            for await event in eventStream {
                await self?.handleEvent(event, agentID: id)
            }
        }
        entries[id] = entry
        if isKeyed {
            keyToAgentID[record.key] = id
            store.save(record)
        }
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

    /// Waits up to `timeoutMs` for something to happen: either the agent goes
    /// idle, or new transcript entries arrive (assistant text, a tool call, a
    /// tool result). Returns whatever accumulated past `since`, so a UI can
    /// render work in progress instead of waiting for the whole turn.
    ///
    /// Never throws on timeout — returns `done: false` with whatever it has.
    public func awaitIdle(id: String, timeoutMs: Int, since: Int? = nil) async throws -> BrowserJSAgentAwaitResult {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        let since = since ?? entry.messages.count
        // Return immediately if there's already something new, or nothing to wait for.
        if entry.status != "running" || entry.messages.count > since || hasUnclaimedToolCalls(agentID: id) {
            return snapshotResult(entry, agentID: id, since: since)
        }
        _ = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { [weak self] in
                await withCheckedContinuation { c in
                    Task { await self?.addIdleWaiter(id: id, since: since, continuation: c) }
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
        return snapshotResult(latest, agentID: id, since: since)
    }

    /// Answer a tool call the agent is waiting on. The agent resumes as soon
    /// as this lands.
    public func respondTool(callId: String, text: String, isError: Bool) throws {
        guard var parked = parkedToolCalls[callId] else {
            throw BrowserJSError.invalidArgs("unknown or already-answered tool call: \(callId)")
        }
        parkedToolCalls[callId] = nil
        parked.timeoutTask?.cancel()
        parked.continuation?.resume(returning: AgentToolOutput(text: text, isError: isError))
    }

    /// Bridges an app's JS tool into the agent: the agent's call is parked
    /// here until the app picks it up via `await` and answers it.
    private func makeAppTool(_ spec: BrowserJSAgentToolSpec, agentID: String) -> AgentToolDefinition {
        AgentToolDefinition(
            name: spec.name,
            description: spec.description,
            inputSchemaJSON: spec.inputSchemaJSON
        ) { [weak self] inputJSON in
            guard let self else { return AgentToolOutput(text: "app is gone", isError: true) }
            return await self.parkToolCall(agentID: agentID, name: spec.name, inputJSON: inputJSON)
        }
    }

    private func parkToolCall(agentID: String, name: String, inputJSON: String) async -> AgentToolOutput {
        let callID = "call-" + String(UUID().uuidString.lowercased().prefix(8))
        let call = BrowserJSAgentToolCall(callId: callID, name: name, inputJSON: inputJSON)
        return await withCheckedContinuation { continuation in
            var parked = ParkedToolCall(call: call, agentID: agentID)
            parked.continuation = continuation
            parked.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.appToolTimeout ?? 120) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timeOutToolCall(callID)
            }
            parkedToolCalls[callID] = parked
            // Wake `await` so the app sees the call immediately.
            resumeIdleWaiters(id: agentID)
        }
    }

    private func timeOutToolCall(_ callID: String) {
        guard var parked = parkedToolCalls[callID] else { return }
        parkedToolCalls[callID] = nil
        parked.continuation?.resume(returning: AgentToolOutput(
            text: "the app did not respond to `\(parked.call.name)` in time", isError: true))
    }

    /// Tool calls this agent is waiting on that haven't been handed out yet.
    private func claimToolCalls(agentID: String) -> [BrowserJSAgentToolCall] {
        var claimed: [BrowserJSAgentToolCall] = []
        for (callID, parked) in parkedToolCalls where parked.agentID == agentID && !parked.handedOut {
            parkedToolCalls[callID]?.handedOut = true
            claimed.append(parked.call)
        }
        return claimed.sorted { $0.callId < $1.callId }
    }

    public func messages(id: String, since: Int) throws -> [BrowserJSAgentMessage] {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        return entry.messages.filter { $0.index >= since }
    }

    /// Live agents plus saved-but-not-loaded ones (status "saved"), so a UI can
    /// offer to reopen a past session.
    public func list() -> [BrowserJSAgentInfo] {
        var infos = entries.map { id, e in
            BrowserJSAgentInfo(id: id, key: e.key, name: e.name, model: e.model,
                               status: e.status, messageCount: e.messages.count)
        }
        let liveKeys = Set(entries.values.compactMap(\.key))
        for record in store.all() where !liveKeys.contains(record.key) {
            infos.append(BrowserJSAgentInfo(
                id: record.agentID, key: record.key, name: record.name,
                model: record.model, status: "saved", messageCount: 0
            ))
        }
        return infos.sorted { $0.id < $1.id }
    }

    public func interrupt(id: String) async throws {
        guard let entry = entries[id] else { throw BrowserJSError.invalidArgs("unknown agent: \(id)") }
        await entry.agent.interrupt()
    }

    /// Shuts the agent down and forgets it, including any saved session.
    public func dispose(id: String) async throws {
        guard var entry = entries[id] else {
            // Not loaded — it may still be a saved session; drop that.
            if let record = store.all().first(where: { $0.agentID == id }) {
                keyToAgentID[record.key] = nil
                store.delete(key: record.key)
                return
            }
            throw BrowserJSError.invalidArgs("unknown agent: \(id)")
        }
        entry.status = "disposed"
        entry.eventTask?.cancel()
        entries[id] = entry
        if let key = entry.key {
            keyToAgentID[key] = nil
            store.delete(key: key)
        }
        resumeIdleWaiters(id: id)
        await entry.agent.shutdown()
    }

    // MARK: - Internals

    private func snapshotResult(_ entry: Entry, agentID: String, since: Int) -> BrowserJSAgentAwaitResult {
        BrowserJSAgentAwaitResult(
            done: entry.status != "running",
            status: entry.status,
            text: entry.lastResult?.text,
            isError: entry.lastResult?.isError ?? false,
            messages: entry.messages.filter { $0.index >= since },
            nextIndex: entry.messages.count,
            toolCalls: claimToolCalls(agentID: agentID)
        )
    }

    private func hasUnclaimedToolCalls(agentID: String) -> Bool {
        parkedToolCalls.values.contains { $0.agentID == agentID && !$0.handedOut }
    }

    private func addIdleWaiter(id: String, since: Int, continuation: CheckedContinuation<Void, Never>) {
        // Re-check: the turn may have progressed between the caller's check and now.
        guard let entry = entries[id] else { continuation.resume(); return }
        if entry.status != "running" || entry.messages.count > since || hasUnclaimedToolCalls(agentID: id) {
            continuation.resume()
            return
        }
        idleWaiters[id, default: []].append(continuation)
    }

    /// Wakes anyone waiting on this agent — on new transcript entries as well
    /// as on going idle, so `awaitIdle` doubles as a progress long-poll.
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
        var turnEnded = false
        switch event {
        case .started(let sessionID):
            // The handle we resume this conversation from later.
            entry.sessionID = sessionID
        case .assistantText(let text):
            append(role: "assistant", text: text)
        case .thinking(let text):
            if !text.isEmpty { append(role: "thinking", text: text) }
        case .toolUse(let name, let inputJSON):
            append(role: "tool_use", text: inputJSON, toolName: name)
        case .toolResult(let text, let isError):
            append(role: "tool_result", text: isError ? "[error] \(text)" : text)
        case .interrupted:
            append(role: "stopped", text: "(stopped)")
        case .turnCompleted(let result):
            entry.status = "idle"
            entry.lastResult = result
            if result.isError { append(role: "error", text: result.text) }
            turnEnded = true
        case .failed(let message):
            entry.status = "idle"
            entry.lastResult = AgentTurnResult(text: message, isError: true)
            append(role: "error", text: message)
            turnEnded = true
        case .terminated:
            break
        }
        entries[agentID] = entry
        persist(agentID: agentID, force: turnEnded)
        // Wake waiters on every new entry, not just at end of turn, so
        // `awaitIdle` delivers tool calls and text as they happen.
        resumeIdleWaiters(id: agentID)
    }

    /// Saves a keyed agent's session id so it can be resumed later. The
    /// transcript is not persisted — a reattached agent remembers the
    /// conversation itself rather than replaying messages at the caller.
    private func persist(agentID: String, force: Bool) {
        guard let entry = entries[agentID], let key = entry.key, var record = entry.record else { return }
        // Between turns is enough — no need to rewrite on every event.
        guard force, record.sessionID != entry.sessionID else { return }
        record.key = key
        record.sessionID = entry.sessionID
        entries[agentID]?.record = record
        store.save(record)
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
