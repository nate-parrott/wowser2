import XCTest
@testable import Core

#if os(macOS)

// Integration tests that drive the real `claude` CLI. They're skipped when the
// binary isn't installed. Cheap model + tiny prompts to keep runs fast.
final class ClaudeCodeAgentTests: XCTestCase {

    // 32x32 solid red PNG.
    static let redPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg=="

    private func requireClaude() throws {
        try XCTSkipUnless(ClaudeCodeAgent.discoverClaudeBinary() != nil, "claude CLI not installed")
    }

    private func makeAgent(tools: [AgentToolDefinition] = [], systemPrompt: String? = nil) -> ClaudeCodeAgent {
        ClaudeCodeAgent(configuration: .init(
            model: "haiku",
            systemPrompt: systemPrompt,
            tools: tools,
            turnTimeout: 120
        ))
    }

    func testBasicAndMultiTurn() async throws {
        try requireClaude()
        let agent = makeAgent()
        defer { Task { await agent.shutdown() } }

        let first = try await agent.send(AgentUserMessage(text: "My name is Waldo. Reply with exactly the word: pong"))
        XCTAssertFalse(first.isError, "turn errored: \(first.text)")
        XCTAssertTrue(first.text.lowercased().contains("pong"), "unexpected reply: \(first.text)")
        let sid = await agent.sessionID
        XCTAssertNotNil(sid)

        // Second turn in the same session must remember the first.
        let second = try await agent.send(AgentUserMessage(text: "What is my name? Answer with just the name."))
        XCTAssertTrue(second.text.contains("Waldo"), "agent forgot context: \(second.text)")
    }

    func testCustomToolRoundTrip() async throws {
        try requireClaude()
        let invoked = Invoked()
        let tool = AgentToolDefinition(
            name: "get_secret_number",
            description: "Returns the secret number.",
            inputSchemaJSON: #"{"type":"object","properties":{}}"#
        ) { _ in
            await invoked.mark()
            return AgentToolOutput(text: "The secret number is 7433.")
        }
        let agent = makeAgent(tools: [tool])
        defer { Task { await agent.shutdown() } }

        let result = try await agent.send(AgentUserMessage(text: "Use the get_secret_number tool and tell me the number."))
        XCTAssertFalse(result.isError, "turn errored: \(result.text)")
        let wasInvoked = await invoked.value
        XCTAssertTrue(wasInvoked, "tool handler never ran")
        XCTAssertTrue(result.text.contains("7433"), "unexpected reply: \(result.text)")
    }

    func testImageInput() async throws {
        try requireClaude()
        let agent = makeAgent()
        defer { Task { await agent.shutdown() } }

        let image = BrowserJSImage(mime: "image/png", data: Self.redPNGBase64)
        let result = try await agent.send(AgentUserMessage(
            text: "What color is this image? Answer with one word.",
            images: [image]
        ))
        XCTAssertFalse(result.isError, "turn errored: \(result.text)")
        XCTAssertTrue(result.text.lowercased().contains("red"), "unexpected reply: \(result.text)")
    }

    /// A Stop button: interrupt ends the turn promptly and reports a clean
    /// stop rather than an error.
    func testInterruptStopsTurn() async throws {
        try requireClaude()
        let agent = makeAgent()
        defer { Task { await agent.shutdown() } }

        let started = Date()
        async let turn = agent.send(AgentUserMessage(
            text: "Count slowly from 1 to 500, one number per line. Do not stop early."))
        try await Task.sleep(nanoseconds: 4_000_000_000)
        await agent.interrupt()

        let result = try await turn
        XCTAssertLessThan(Date().timeIntervalSince(started), 45, "interrupt should end the turn promptly")
        XCTAssertEqual(result.stopReason, "interrupted")
        XCTAssertFalse(result.isError, "a deliberate stop is not an error")
    }

    /// Messages sent while the agent is working are delivered immediately and
    /// answered in order — that's how a UI steers a running agent.
    func testSendWhileWorkingQueuesInOrder() async throws {
        try requireClaude()
        let agent = makeAgent()
        defer { Task { await agent.shutdown() } }

        async let firstTurn = agent.send(AgentUserMessage(text: "Say the word ALPHA and nothing else."))
        try await Task.sleep(nanoseconds: 500_000_000)
        // Sent mid-turn: must not block behind the first turn.
        async let secondTurn = agent.send(AgentUserMessage(text: "Say the word BETA and nothing else."))

        let (first, second) = try await (firstTurn, secondTurn)
        XCTAssertTrue(first.text.contains("ALPHA"), "first turn: \(first.text)")
        XCTAssertTrue(second.text.contains("BETA"), "second turn: \(second.text)")
    }

    func testEventsStream() async throws {
        try requireClaude()
        let agent = makeAgent()
        defer { Task { await agent.shutdown() } }

        let events = await agent.events()
        let collector = Task { () -> (sawStart: Bool, sawText: Bool, sawCompleted: Bool) in
            var start = false, text = false, completed = false
            for await event in events {
                switch event {
                case .started: start = true
                case .assistantText: text = true
                case .turnCompleted: completed = true; return (start, text, completed)
                default: break
                }
            }
            return (start, text, completed)
        }

        _ = try await agent.send(AgentUserMessage(text: "Reply with exactly the word: pong"))
        let seen = await collector.value
        XCTAssertTrue(seen.sawStart)
        XCTAssertTrue(seen.sawText)
        XCTAssertTrue(seen.sawCompleted)
    }
}

private actor Invoked {
    private(set) var value = false
    func mark() { value = true }
}

#endif
