#if os(macOS)
import XCTest
import MCP
@testable import Core

/// Regression tests for the "one MCP client forever" lockout.
///
/// Two independent layers each rejected a second client, and fixing only the
/// first leaves the server broken:
///
///  1. `StatefulHTTPServerTransport` kept a single `sessionID` that was never
///     cleared → second `initialize` got HTTP 400 "Session already initialized".
///  2. `Server`'s default `initialize` handler guards on `isInitialized` →
///     second `initialize` got HTTP 200 carrying a JSON-RPC error,
///     "Server is already initialized".
///
/// Claude Code reported both as an OAuth/auth failure, because a failed
/// `initialize` sends it down its OAuth-discovery fallback path.
///
/// `MCPServer.start()` therefore uses `StatelessHTTPServerTransport` *and*
/// overrides the `initialize` handler after `start()`. These tests mirror that
/// composition and assert on JSON-RPC bodies — asserting on HTTP status alone
/// would pass against the half-fix.
final class MCPTransportSessionTests: XCTestCase {

    private let serverName = "WowserTest"
    private let serverVersion = "0.1.0"
    private var capabilities: Server.Capabilities {
        Server.Capabilities(tools: .init(listChanged: false))
    }

    /// Mirrors the pipeline built in `MCPServer.start()`.
    private func makePipeline() -> StandardValidationPipeline {
        StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    }

    /// Note: no `Origin` header — Claude Code is a CLI, not a browser, and
    /// `OriginValidator.localhost()` rejects a browser-style Origin.
    private func post(_ json: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "MCP-Protocol-Version": "2025-06-18",
            ],
            body: Data(json.utf8),
            path: "/mcp"
        )
    }

    private var initializeBody: String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    }

    /// A JSON-RPC 200 can still carry an `error`. Check the body, not the status.
    private func assertJSONRPCSuccess(_ resp: HTTPResponse, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(resp.statusCode, 200, "\(what): unexpected HTTP status", file: file, line: line)
        guard let data = resp.bodyData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(what): empty or unparseable body", file: file, line: line)
            return
        }
        if let err = obj["error"] as? [String: Any] {
            XCTFail("\(what): JSON-RPC error: \(err["message"] ?? err)", file: file, line: line)
            return
        }
        XCTAssertNotNil(obj["result"], "\(what): no result field", file: file, line: line)
    }

    /// Builds the same transport + server + override that `MCPServer.start()` does.
    private func makeStartedTransport() async throws -> StatelessHTTPServerTransport {
        let transport = StatelessHTTPServerTransport(validationPipeline: makePipeline())
        let caps = capabilities
        let (name, version) = (serverName, serverVersion)

        let server = Server(name: name, version: version, capabilities: caps)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Tool(name: "probe", description: "probe", inputSchema: .object([:]))])
        }
        try await server.start(transport: transport)
        await server.withMethodHandler(Initialize.self) { params in
            let negotiated = Version.supported.contains(params.protocolVersion)
                ? params.protocolVersion
                : Version.latest
            return Initialize.Result(
                protocolVersion: negotiated,
                capabilities: caps,
                serverInfo: Server.Info(name: name, version: version),
                instructions: nil
            )
        }
        return transport
    }

    /// The bug: the second and third clients must not be locked out.
    func testManyClientsCanEachInitializeAndListTools() async throws {
        let transport = try await makeStartedTransport()

        for client in 1...3 {
            let initResp = await transport.handleRequest(post(initializeBody))
            assertJSONRPCSuccess(initResp, "client \(client) initialize")

            let toolsResp = await transport.handleRequest(post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            assertJSONRPCSuccess(toolsResp, "client \(client) tools/list")
        }
    }

    /// Pins the layer-1 fix: a stateless transport hands out no session id, so
    /// there is no single session slot for one client to squat.
    func testStatelessTransportEmitsNoSessionID() async throws {
        let transport = try await makeStartedTransport()
        let resp = await transport.handleRequest(post(initializeBody))
        XCTAssertNil(
            resp.headers.first(where: { $0.key.lowercased() == "mcp-session-id" }),
            "stateless transport must not hand out a session id"
        )
    }

    /// Documents the behavior change: stateless serves POST only. Claude Code
    /// tolerates 405 on the optional GET/SSE channel.
    func testGetReturns405() async throws {
        let transport = try await makeStartedTransport()
        let resp = await transport.handleRequest(
            HTTPRequest(method: "GET", headers: [:], body: nil, path: "/mcp")
        )
        XCTAssertEqual(resp.statusCode, 405)
    }
}
#endif
