#if os(macOS)
import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

// Wowser-side MCP server.
//
// - HTTP transport (Q19) using StatelessHTTPServerTransport.
// - Bound to 127.0.0.1 only (Q20-ish, "loopback only, no other clients").
// - Started at app launch, lives forever (Q21).
// - Exposes exactly four tools per Section 6 of the spec.
//
// The 4 tools wrap a shared BrowserJSRuntime + BrowserJSHelpers.
public actor MCPServer {
    public static let shared = MCPServer(host: BrowserJSLiveHost.shared, helpers: BrowserJSHelpers.shared)

    /// Fixed loopback port. We pick a stable port so the `claude mcp add`
    /// command in Settings stays valid across launches. If something else is
    /// holding it, start() falls back to a random port and updates the URL.
    public static let preferredPort: Int = 48197

    private let runtime: BrowserJSRuntime
    private let helpers: BrowserJSHelpersProvider
    private let host: any BrowserJSHost

    private var listenChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var transport: StatefulHTTPServerTransport?
    private var server: Server?
    private(set) public var boundPort: Int?
    private(set) public var authKey: String?

    public init(host: any BrowserJSHost, helpers: BrowserJSHelpersProvider) {
        self.host = host
        self.helpers = helpers
        self.runtime = BrowserJSRuntime(host: host, helpers: helpers)
    }

    /// Start the server. Call once at app launch. Tries `preferredPort` first;
    /// falls back to a random ephemeral port if that's taken.
    public func start(port: Int = MCPServer.preferredPort) async throws {
        if listenChannel != nil { return }

        // Auth key is baked into the URL path (`/mcp/<key>`). The HTTP handler
        // 404s any other path. Persisted across launches so the `claude mcp
        // add` command stays stable.
        let key: String = {
            if let existing = UserDefaults.standard.string(forKey: DefaultsKeys.mcpServerToken.rawValue),
               !existing.isEmpty {
                return existing
            }
            return Self.generateAuthKey()
        }()
        self.authKey = key

        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

        let transport = StatefulHTTPServerTransport(validationPipeline: pipeline)
        let server = Server(
            name: "Wowser",
            version: "0.1.0",
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )
        self.transport = transport
        self.server = server
        await registerHandlers(on: server)
        try await server.start(transport: transport)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [transport, key] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(transport: transport, authKey: key))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let chan: Channel
        do {
            chan = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        } catch {
            // Preferred port is busy. Fall back to a random one so the server
            // still works; the displayed URL in Settings will reflect it.
            FileHandle.standardError.write(Data("Wowser MCP: port \(port) unavailable (\(error)); falling back to random port.\n".utf8))
            chan = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        }
        self.listenChannel = chan
        self.boundPort = chan.localAddress?.port
        // Auth key is baked into the URL path. The HTTP handler validates that
        // the request path matches `/mcp/<key>` exactly. This means the
        // `claude mcp add ...` install command in Settings carries the key,
        // and the model never has to read it from anywhere — Claude Code's
        // HTTP MCP client just hits the URL.
        let url = "http://127.0.0.1:\(self.boundPort ?? -1)/mcp/\(key)"
        FileHandle.standardError.write(Data("Wowser MCP server listening on \(url)\n".utf8))
        UserDefaults.standard.set(url, forKey: DefaultsKeys.mcpServerURL.rawValue)
        UserDefaults.standard.set(key, forKey: DefaultsKeys.mcpServerToken.rawValue)
    }

    private static func generateAuthKey() -> String {
        // 8 chars of base62 — ~47 bits. Plenty for a loopback-only server, and
        // short enough to be inconsequential to read/type.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    public func stop() async {
        if let chan = listenChannel { try? await chan.close() }
        listenChannel = nil
        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil
        await server?.stop()
    }

    private func registerHandlers(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return ListTools.Result(tools: []) }
            let tools = await self.declareTools()
            return ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(content: [.text(text: "server unavailable", annotations: nil, _meta: nil)], isError: true)
            }
            return await self.handleToolCall(name: params.name, arguments: params.arguments)
        }
    }

    private func declareTools() -> [MCP.Tool] {
        let runBrowserJS = MCP.Tool(
            name: "run_browser_js",
            description: """
            Run JS in the privileged BrowserJS environment (a JSContext with a
            global `browser` object). Persisted helpers are prepended in alpha
            order. The JS may use top-level `await`. The value of the final
            expression is returned in `result`. To return a value from
            multi-statement code, end with a bare expression (e.g. `let x = 1; x + 1`).
            To see screenshots, call `browser.viewImage(await browser.content.screenshot(tabId))`
            — they're attached as image content blocks alongside the result.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object(["type": .string("string"), "description": .string("BrowserJS source. May use top-level await.")]),
                ]),
                "required": .array([.string("code")]),
            ])
        )
        let saveHelper = MCP.Tool(
            name: "save_browser_helper_file",
            description: "Persist a BrowserJS helper file. Helpers are prepended (alpha order) to every run_browser_js evaluation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("alphanumerics + _ - only.")]),
                    "content": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("name"), .string("content")]),
            ])
        )
        let readHelper = MCP.Tool(
            name: "read_browser_helper_file",
            description: "Return one helper by name, or all helpers if no name is given.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                ]),
            ])
        )
        let getDocs = MCP.Tool(
            name: "get_browser_js_docs",
            description: "Return the BrowserJS .d.ts declaration source. Call this first to learn the `browser.*` API.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )
        return [runBrowserJS, saveHelper, readHelper, getDocs]
    }

    private func handleToolCall(name: String, arguments: [String: MCP.Value]?) async -> CallTool.Result {
        // Auth happens at the HTTP layer (path validation in MCPHTTPHandler);
        // by the time we get here, the request was authorized.

        do {
            switch name {
            case "run_browser_js":
                guard let args = arguments, case .string(let code) = args["code"] ?? .null else {
                    throw BrowserJSError.invalidArgs("code")
                }
                let result = await runtime.run(code: code)
                let text = encodeRunResult(result)
                var content: [MCP.Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
                for img in result.images where !img.data.isEmpty {
                    content.append(.image(data: img.data, mimeType: img.mime, annotations: nil, _meta: nil))
                }
                return CallTool.Result(
                    content: content,
                    isError: result.error != nil
                )

            case "save_browser_helper_file":
                guard let args = arguments,
                      case .string(let helperName) = args["name"] ?? .null,
                      case .string(let content) = args["content"] ?? .null
                else { throw BrowserJSError.invalidArgs("name, content") }
                try helpers.saveHelper(name: helperName, content: content)
                return CallTool.Result(content: [.text("{\"ok\":true}")])

            case "read_browser_helper_file":
                let helperName: String? = {
                    if case .string(let s) = arguments?["name"] ?? .null { return s }
                    return nil
                }()
                if let helperName {
                    let content = try helpers.readHelper(name: helperName) ?? ""
                    let json: [String: Any] = ["files": [["name": helperName, "content": content]]]
                    let data = try JSONSerialization.data(withJSONObject: json)
                    return CallTool.Result(content: [.text(String(data: data, encoding: .utf8) ?? "{}")])
                } else {
                    let entries = try helpers.listHelpers()
                    let json: [String: Any] = ["files": entries.map { ["name": $0.name, "content": $0.content] }]
                    let data = try JSONSerialization.data(withJSONObject: json)
                    return CallTool.Result(content: [.text(String(data: data, encoding: .utf8) ?? "{}")])
                }

            case "get_browser_js_docs":
                let dts = BrowserJSDocs.dts
                let payload: [String: Any] = ["dts": dts]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return CallTool.Result(content: [.text(String(data: data, encoding: .utf8) ?? "{}")])

            default:
                return CallTool.Result(content: [.text("unknown tool: \(name)")], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }
    }

    /// Build the run_browser_js response text. The runtime stores `result` as
    /// a JSON string; if we just JSONEncoder-encode the struct, the result gets
    /// double-stringified (model sees `"result": "42"` instead of `"result": 42`).
    /// We re-parse and inline so the model can read the value directly.
    private func encodeRunResult(_ r: BrowserJSResult) -> String {
        var dict: [String: Any] = [
            "logs": r.logs,
            "truncated": r.truncated,
        ]
        if let err = r.error {
            dict["error"] = err
        } else {
            dict["error"] = NSNull()
        }
        if let resJSON = r.result, let data = resJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            dict["result"] = parsed
        } else {
            dict["result"] = NSNull()
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

// MARK: - NIO HTTP adapter

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let transport: StatefulHTTPServerTransport
    private let authKey: String
    private struct State { var head: HTTPRequestHead; var body: ByteBuffer }
    private var state: State?

    init(transport: StatefulHTTPServerTransport, authKey: String) {
        self.transport = transport
        self.authKey = authKey
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state = State(head: head, body: context.channel.allocator.buffer(capacity: 0))
        case .body(var buf):
            state?.body.writeBuffer(&buf)
        case .end:
            guard let s = state else { return }
            state = nil
            nonisolated(unsafe) let ctx = context
            Task {
                await self.handle(state: s, context: ctx)
            }
        }
    }

    private func handle(state: State, context: ChannelHandlerContext) async {
        let path = state.head.uri.split(separator: "?").first.map(String.init) ?? state.head.uri
        // Auth key is baked into the path (`/mcp/<key>`). Anything else 404s,
        // including `/mcp` without a key — we don't want to leak the existence
        // of a valid endpoint to drive-by probes.
        let expected = "/mcp/\(authKey)"
        guard path == expected else {
            await respondSimple(context: context, version: state.head.version, status: 404, headers: [:], body: nil)
            return
        }
        var headers: [String: String] = [:]
        for (n, v) in state.head.headers {
            if let existing = headers[n] { headers[n] = existing + ", " + v } else { headers[n] = v }
        }
        let bodyData: Data?
        if state.body.readableBytes > 0,
           let bytes = state.body.getBytes(at: 0, length: state.body.readableBytes) {
            bodyData = Data(bytes)
        } else {
            bodyData = nil
        }
        // Strip the auth key from the path before handing to the transport,
        // so the transport sees a clean `/mcp` regardless of the URL the
        // client used. (StatefulHTTPServerTransport may route by path.)
        let req = HTTPRequest(method: state.head.method.rawValue, headers: headers, body: bodyData, path: "/mcp")
        let resp = await transport.handleRequest(req)

        if case .stream(let stream, _) = resp {
            await respondStream(context: context, version: state.head.version, status: resp.statusCode, headers: resp.headers, stream: stream)
        } else {
            await respondSimple(context: context, version: state.head.version, status: resp.statusCode, headers: resp.headers, body: resp.bodyData)
        }
    }

    private func respondSimple(context: ChannelHandlerContext, version: HTTPVersion, status: Int, headers: [String: String], body: Data?) async {
        nonisolated(unsafe) let ctx = context
        let el = ctx.eventLoop
        el.execute {
            var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status))
            for (n, v) in headers { head.headers.add(name: n, value: v) }
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let body, !body.isEmpty {
                var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private func respondStream(context: ChannelHandlerContext, version: HTTPVersion, status: Int, headers: [String: String], stream: AsyncThrowingStream<Data, Swift.Error>) async {
        nonisolated(unsafe) let ctx = context
        let el = ctx.eventLoop
        el.execute {
            var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status))
            for (n, v) in headers { head.headers.add(name: n, value: v) }
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            ctx.flush()
        }
        do {
            for try await chunk in stream {
                el.execute {
                    var buf = ctx.channel.allocator.buffer(capacity: chunk.count)
                    buf.writeBytes(chunk)
                    ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                }
            }
        } catch {
            // stream ended in error — fall through to close
        }
        el.execute {
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
#endif
