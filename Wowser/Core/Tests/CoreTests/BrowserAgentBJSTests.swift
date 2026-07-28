import XCTest
@testable import Core

#if os(macOS)

// Exercises the `browser.agent.*` BJS surface end-to-end through
// BrowserJSRuntime -> BrowserJSDispatch -> host -> BrowserAgentManager,
// using a fake in-process Agent (no CLI, no network).
final class BrowserAgentBJSTests: XCTestCase {

    func testAgentLifecycleViaBJS() async throws {
        let manager = BrowserAgentManager(provider: EchoProvider(), host: StubHost(), helpers: NoHelpers())
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
        let manager = BrowserAgentManager(provider: nil, host: StubHost(), helpers: NoHelpers())
        do {
            _ = try await manager.create(options: .init())
            XCTFail("expected create to throw with no provider")
        } catch {
            XCTAssertTrue("\(error)".contains("no agent implementation"), "\(error)")
        }
    }
}

// MARK: - Fakes

/// Echoes every message back as "echo: <text>" after emitting proper events.
private final class EchoAgent: Agent, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<AgentEvent>.Continuation] = []

    func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
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

private struct EchoProvider: AgentProvider {
    let id = "echo"
    var isAvailable: Bool { true }
    func makeAgent(_ spec: AgentSpec) -> any Agent { EchoAgent() }
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
    func agentAwait(id: String, timeoutMs: Int) async throws -> BrowserJSAgentAwaitResult {
        try await requireManager().awaitIdle(id: id, timeoutMs: timeoutMs)
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
