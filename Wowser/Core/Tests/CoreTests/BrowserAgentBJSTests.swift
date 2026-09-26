import XCTest
@testable import Core

#if os(macOS)

// Exercises the `browser.agent.*` BJS surface end-to-end through
// BrowserJSRuntime -> BrowserJSDispatch -> host -> BrowserAgentManager,
// using a fake in-process Agent (no CLI, no network).
final class BrowserAgentBJSTests: XCTestCase {

    func testAgentLifecycleViaBJS() async throws {
        let manager = BrowserAgentManager(provider: EchoProvider(), host: StubHost(), helpers: NoHelpers(), store: MemoryStore())
        let host = StubHost(manager: manager)
        let runtime = BrowserJSRuntime(host: host, helpers: NoHelpers())

        let result = await runtime.run(code: """
            const id = await browser.agent.create({ name: 'T', model: 'sonnet', effort: 'low', exposeBrowserJS: false });
            await browser.agent.send({ id, text: 'hello' });
            let r = await browser.agent.await({ id, timeoutMs: 5000 });
            const msgs = await browser.agent.messages({ id });
            const listed = await browser.agent.list();
            await browser.agent.dispose(id);
            const after = await browser.agent.list();
            return {
                done: r.done,
                text: r.text,
                roles: msgs.map(m => m.role),
                listedStatus: listed[0].status,
                listedModel: listed[0].model,
                afterStatus: after[0].status,
            };
            """)

        XCTAssertNil(result.error, result.error ?? "")
        let json = try XCTUnwrap(result.result)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["done"] as? Bool, true)
        XCTAssertEqual(obj["text"] as? String, "echo: hello")
        XCTAssertEqual(obj["roles"] as? [String], ["user", "assistant"])
        XCTAssertEqual(obj["listedStatus"] as? String, "idle")
        XCTAssertEqual(obj["listedModel"] as? String, "sonnet")
        XCTAssertEqual(obj["afterStatus"] as? String, "disposed")
    }

    func testCreateFailsWithoutProvider() async throws {
        let manager = BrowserAgentManager(provider: nil, host: StubHost(), helpers: NoHelpers(), store: MemoryStore())
        do {
            _ = try await manager.create(options: .init())
            XCTFail("expected create to throw with no provider")
        } catch {
            XCTAssertTrue("\(error)".contains("no agent implementation"), "\(error)")
        }
    }

    /// A keyed agent is the same agent across reloads: same id, transcript
    /// restored, and the harness told to resume the prior conversation.
    func testKeyedAgentPersistsAndResumes() async throws {
        let store = MemoryStore()
        let provider = EchoProvider()

        let first = BrowserAgentManager(provider: provider, host: StubHost(), helpers: NoHelpers(), store: store)
        let id = try await first.create(options: .init(key: "chat", model: "sonnet"))
        try await first.send(id: id, text: "hello", images: [])
        try await drain(first, id: id)

        // Same key on a live manager returns the same agent, not a new one.
        let again = try await first.create(options: .init(key: "chat"))
        XCTAssertEqual(again, id)

        // A fresh manager (app restart) resumes from disk.
        let second = BrowserAgentManager(provider: provider, host: StubHost(), helpers: NoHelpers(), store: store)
        let resumedID = try await second.create(options: .init(key: "chat"))
        XCTAssertEqual(resumedID, id, "resumed agent should keep its id")

        // Memory comes from resuming the harness session; the transcript is
        // restored from disk so the UI shows history and indices continue.
        let resumedSessions = await provider.resumedSessionIDs
        XCTAssertEqual(resumedSessions, ["echo-session"], "harness should be asked to resume the prior session")
        let restored = try await second.messages(id: resumedID, since: 0)
        XCTAssertEqual(restored.map(\.role), ["user", "assistant"], "saved transcript should be restored")
        try await second.send(id: resumedID, text: "again", images: [])
        try await drain(second, id: resumedID)
        let after = try await second.messages(id: resumedID, since: 0)
        XCTAssertEqual(after.map(\.index), Array(0..<after.count), "indices continue past the restored transcript")
        XCTAssertEqual(after.count, 4)
    }

    /// `await` returns as soon as there's something new, so a UI can render
    /// tool calls and partial output mid-turn.
    func testAwaitReturnsProgressBeforeTurnEnds() async throws {
        let agent = SlowAgent()
        let manager = BrowserAgentManager(provider: FixedProvider(agent: agent), host: StubHost(), helpers: NoHelpers(), store: MemoryStore())
        let id = try await manager.create(options: .init())
        try await manager.send(id: id, text: "go", images: [])

        await agent.emitToolUse()
        let progress = try await manager.awaitIdle(id: id, timeoutMs: 3000, since: 1)
        XCTAssertFalse(progress.done, "turn is still running")
        XCTAssertEqual(progress.messages.map(\.role), ["tool_use"])

        await agent.finish()
        var roles: [String] = []
        var since = progress.nextIndex
        while true {
            let r = try await manager.awaitIdle(id: id, timeoutMs: 3000, since: since)
            roles += r.messages.map(\.role)
            since = r.nextIndex
            if r.done { break }
        }
        XCTAssertEqual(roles, ["assistant"])
    }

    /// An app declares a tool, serves it with a JS callback, and the agent's
    /// call round-trips through that callback and back into the agent.
    func testAppProvidedJSToolRoundTrip() async throws {
        let agent = ToolCallingAgent()
        let manager = BrowserAgentManager(provider: FixedProvider(agent: agent), host: StubHost(), helpers: NoHelpers(), store: MemoryStore())
        let host = StubHost(manager: manager)
        let runtime = BrowserJSRuntime(host: host, helpers: NoHelpers())

        let result = await runtime.run(code: """
            const id = await browser.agent.create({
              exposeBrowserJS: false,
              tools: [{
                name: 'add_todo',
                description: 'Add a todo item.',
                inputSchema: { type: 'object', properties: { title: { type: 'string' } } },
              }],
            });
            const added = [];
            await browser.agent.send({ id, text: 'add milk' });
            await browser.agent.serve(id, {
              add_todo: async (args) => { added.push(args.title); return { ok: true, count: added.length }; },
            });
            return added;
            """)

        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.result, #"["milk"]"#, "app callback should have run with the agent's args")
        let toolOutput = await agent.receivedToolOutput
        XCTAssertEqual(toolOutput?.isError, false)
        // The handler's return value reaches the agent as JSON (key order is
        // not guaranteed, so compare parsed).
        let returned = try XCTUnwrap(toolOutput?.text)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(returned.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["ok"] as? Bool, true)
        XCTAssertEqual(parsed["count"] as? Int, 1)
    }

    /// `await` resolves on progress, so callers loop until `done`.
    private func drain(_ manager: BrowserAgentManager, id: String) async throws {
        var since = 0
        for _ in 0..<20 {
            let r = try await manager.awaitIdle(id: id, timeoutMs: 2000, since: since)
            since = r.nextIndex
            if r.done { return }
        }
        XCTFail("agent never went idle")
    }
}

// MARK: - Fakes

/// Echoes every message back as "echo: <text>" after emitting proper events.
private final class EchoAgent: Agent, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<AgentEvent>.Continuation] = []

    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
        emit(.started(sessionID: "echo-session"))
        let result = AgentTurnResult(text: "echo: \(message.text)")
        emit(.assistantText(result.text))
        emit(.turnCompleted(result))
        return result
    }

    func events() async -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            lock.lock(); continuations.append(c); lock.unlock()
        }
    }

    func interrupt() async {}
    func shutdown() async { emit(.terminated) }

    private func emit(_ event: AgentEvent) {
        lock.lock(); let cs = continuations; lock.unlock()
        for c in cs { c.yield(event) }
    }
}

private final class EchoProvider: AgentProvider, @unchecked Sendable {
    let id = "echo"
    var isAvailable: Bool { true }
    private let lock = NSLock()
    private var _resumed: [String] = []
    /// Session ids the manager asked us to resume — proves persistence wiring.
    var resumedSessionIDs: [String] {
        get async { lock.lock(); defer { lock.unlock() }; return _resumed }
    }
    func makeAgent(_ spec: AgentSpec) -> any Agent {
        if let resume = spec.resumeSessionID {
            lock.lock(); _resumed.append(resume); lock.unlock()
        }
        return EchoAgent()
    }
}

/// Emits events on demand so a test can observe a turn in progress.
private final class SlowAgent: Agent, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<AgentEvent>.Continuation] = []
    private var pending: CheckedContinuation<AgentTurnResult, Error>?

    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
        emit(.started(sessionID: "slow-session"))
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); pending = c; lock.unlock()
        }
    }
    func emitToolUse() { emit(.toolUse(name: "run_browser_js", inputJSON: "{}")) }
    func finish() {
        let result = AgentTurnResult(text: "all done")
        emit(.assistantText(result.text))
        emit(.turnCompleted(result))
        lock.lock(); let c = pending; pending = nil; lock.unlock()
        c?.resume(returning: result)
    }
    func events() async -> AsyncStream<AgentEvent> {
        AsyncStream { c in lock.lock(); continuations.append(c); lock.unlock() }
    }
    func interrupt() async {}
    func shutdown() async {}
    private func emit(_ event: AgentEvent) {
        lock.lock(); let cs = continuations; lock.unlock()
        for c in cs { c.yield(event) }
    }
}

/// On its turn, calls the single app-provided tool it was given, then finishes.
private final class ToolCallingAgent: Agent, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<AgentEvent>.Continuation] = []
    private var tools: [AgentToolDefinition] = []
    private var _receivedToolOutput: AgentToolOutput?
    var receivedToolOutput: AgentToolOutput? {
        get async { lock.lock(); defer { lock.unlock() }; return _receivedToolOutput }
    }

    func configure(tools: [AgentToolDefinition]) {
        lock.lock(); self.tools = tools; lock.unlock()
    }

    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
        emit(.started(sessionID: "tool-session"))
        lock.lock(); let tool = tools.first; lock.unlock()
        if let tool {
            emit(.toolUse(name: tool.name, inputJSON: #"{"title":"milk"}"#))
            let output = await tool.handler(#"{"title":"milk"}"#)
            lock.lock(); _receivedToolOutput = output; lock.unlock()
            emit(.toolResult(text: output.text, isError: output.isError))
        }
        let result = AgentTurnResult(text: "added")
        emit(.assistantText(result.text))
        emit(.turnCompleted(result))
        return result
    }
    func events() async -> AsyncStream<AgentEvent> {
        AsyncStream { c in lock.lock(); continuations.append(c); lock.unlock() }
    }
    func interrupt() async {}
    func shutdown() async {}
    private func emit(_ event: AgentEvent) {
        lock.lock(); let cs = continuations; lock.unlock()
        for c in cs { c.yield(event) }
    }
}

private struct FixedProvider: AgentProvider {
    let id = "fixed"
    let agent: any Agent
    var isAvailable: Bool { true }
    func makeAgent(_ spec: AgentSpec) -> any Agent {
        // Hand the agent the tools the manager bridged for it.
        (agent as? ToolCallingAgent)?.configure(tools: spec.tools)
        return agent
    }
}

private final class MemoryStore: AgentSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: AgentSessionRecord] = [:]
    func load(key: String) -> AgentSessionRecord? {
        lock.lock(); defer { lock.unlock() }; return records[key]
    }
    func save(_ record: AgentSessionRecord) {
        lock.lock(); records[record.key] = record; lock.unlock()
    }
    func delete(key: String) {
        lock.lock(); records[key] = nil; transcripts[key] = nil; lock.unlock()
    }
    func all() -> [AgentSessionRecord] {
        lock.lock(); defer { lock.unlock() }; return Array(records.values)
    }
    private var transcripts: [String: [BrowserJSAgentMessage]] = [:]
    func loadTranscript(key: String) -> [BrowserJSAgentMessage] {
        lock.lock(); defer { lock.unlock() }; return transcripts[key] ?? []
    }
    func saveTranscript(key: String, messages: [BrowserJSAgentMessage]) {
        lock.lock(); transcripts[key] = messages; lock.unlock()
    }
}

private struct NoHelpers: BrowserJSHelpersProvider {
    func saveHelper(name: String, content: String) throws {}
    func readHelper(name: String) throws -> String? { nil }
    func listHelpers() throws -> [(name: String, content: String)] { [] }
    func concatenatedHelpers() throws -> String { "" }
}

/// Minimal host. When given a manager, forwards the agent.* surface to it
/// (defined directly on the conforming class — protocol-extension defaults
/// can't be overridden from a subclass through existential dispatch).
private final class StubHost: BrowserJSHost, @unchecked Sendable {
    let manager: BrowserAgentManager?
    init(manager: BrowserAgentManager? = nil) { self.manager = manager }

    private func requireManager() throws -> BrowserAgentManager {
        guard let manager else { throw BrowserJSError.notImplemented("agent") }
        return manager
    }
    func agentCreate(options: BrowserJSAgentCreateOptions) async throws -> String {
        try await requireManager().create(options: options)
    }
    func agentSend(id: String, text: String, images: [BrowserJSImage]) async throws {
        try await requireManager().send(id: id, text: text, images: images)
    }
    func agentAwait(id: String, timeoutMs: Int, since: Int?) async throws -> BrowserJSAgentAwaitResult {
        try await requireManager().awaitIdle(id: id, timeoutMs: timeoutMs, since: since)
    }
    func agentRespondTool(callId: String, text: String, isError: Bool) async throws {
        try await requireManager().respondTool(callId: callId, text: text, isError: isError)
    }
    func agentMessages(id: String, since: Int) async throws -> [BrowserJSAgentMessage] {
        try await requireManager().messages(id: id, since: since)
    }
    func agentList() async throws -> [BrowserJSAgentInfo] {
        try await requireManager().list()
    }
    func agentInterrupt(id: String) async throws {
        try await requireManager().interrupt(id: id)
    }
    func agentDispose(id: String) async throws {
        try await requireManager().dispose(id: id)
    }

    func tabsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSTabInfo] { [] }
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String { throw BrowserJSError.notImplemented("stub") }
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String { throw BrowserJSError.notImplemented("stub") }
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String { throw BrowserJSError.notImplemented("stub") }
    func tabsClose(id: String) async throws {}
    func tabsActivate(id: String) async throws {}
    func tabsMove(id: String, toIndex: Int) async throws {}
    func tabsGet(id: String) async throws -> BrowserJSTabInfo { throw BrowserJSError.tabNotFound(id) }
    func tabsNavigate(id: String, url: String) async throws {}
    func contentRead(id: String, as kind: String) async throws -> String { throw BrowserJSError.notImplemented("stub") }
    func contentScreenshot(id: String) async throws -> BrowserJSImage { throw BrowserJSError.notImplemented("stub") }
    func pageEval(id: String, js: String) async throws -> Any? { nil }
    func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? { nil }
    func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {}
    func pageType(id: String, text: String) async throws {}
    func pageKey(id: String, key: String, modifiers: [String]) async throws {}
    func pageScroll(id: String, dx: Double, dy: Double) async throws {}
    func windowsList() async throws -> [BrowserJSWindowInfo] { [] }
    func windowsGetCurrent() async throws -> BrowserJSWindowInfo? { nil }
    func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? { nil }
    func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary] { [] }
    func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary] { [] }
    func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse { throw BrowserJSError.notImplemented("stub") }
    func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse { throw BrowserJSError.notImplemented("stub") }
    func netCaptureOrigin(origin: String, enabled: Bool) async throws {}
}

#endif
