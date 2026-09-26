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
    private var transport: StatelessHTTPServerTransport?
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

        // Stateless: no session state, so every client can `initialize`
        // independently. No SessionValidator (there is no session to validate),
        // and `.jsonOnly` because stateless never opens an SSE stream.
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])

        let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
        let serverName = isProd() ? "Wowser" : "WowserDev"
        let serverVersion = "0.1.0"
        let capabilities = Server.Capabilities(tools: .init(listChanged: false))
        let server = Server(name: serverName, version: serverVersion, capabilities: capabilities)
        self.transport = transport
        self.server = server
        await registerHandlers(on: server)
        try await server.start(transport: transport)

        // `Server.start()` installs a default `initialize` handler that rejects
        // a second call with "Server is already initialized" — the same
        // one-client-forever lockout the stateless transport just removed, one
        // layer up. We serve many independent, short-lived CLI clients against
        // one long-lived Server, so re-initialization must be allowed. Override
        // it *after* start(), since start() is what registers the default.
        //
        // Safe because `Server.Configuration.default` is non-strict: the
        // `isInitialized` flag this skips setting only gates requests when
        // `configuration.strict == true`. If we ever enable strict mode, this
        // breaks and initialize must set that state instead.
        await server.withMethodHandler(Initialize.self) { params in
            // Mirrors the SDK's internal `Version.negotiate`, which isn't public.
            let negotiated = Version.supported.contains(params.protocolVersion)
                ? params.protocolVersion
                : Version.latest
            return Initialize.Result(
                protocolVersion: negotiated,
                capabilities: capabilities,
                serverInfo: Server.Info(name: serverName, version: serverVersion),
                instructions: Self.staticInstructions
            )
        }

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

    /// Baseline `initialize.instructions`. `MCPHTTPHandler` appends a live
    /// orientation (what's open in the caller's space) to this per connection.
    static let staticInstructions = """
    This server controls the Wowser browser the user is working in. Start by \
    reading the orientation below (or call `get_browser_context` for a fresh \
    one) so you know which space and tabs you're next to, then call \
    `get_browser_js_docs` before your first `run_browser_js`.
    """

    /// The orientation text for an MCP client, built on the main thread from
    /// the current store state.
    static func orientation(originPaneID: ID<WebContent>?) async -> String {
        await MainActor.run { BrowserStore.shared.model.agentOrientation(originPaneID: originPaneID) }
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
            return await self.handleToolCall(name: params.name, arguments: params.arguments, meta: params._meta)
        }
    }

    private func declareTools() -> [MCP.Tool] {
        let runBrowserJS = MCP.Tool(
            name: "run_browser_js",
            description: """
            Run JS in the privileged BrowserJS environment (a JSContext with a
            global `browser` object). Persisted helpers are prepended in alpha
            order. Your code is the body of an async function: it may use
            top-level `await`, and you MUST `return <expr>` to produce a result
            in `result` (a bare trailing expression yields nothing).
            To see screenshots, call `browser.viewImage(await browser.content.screenshot(tabId))`
            — they're attached as image content blocks alongside the result.

            Work in the BACKGROUND by default: the user is using this browser
            right now. Open pages with `browser.tabs.openGhost(url)` (a hidden
            agent tab that still supports read/screenshot/click/type/key/eval),
            not `tabs.open`, unless the user asked to see the page. Close ghost
            tabs when done. Call `get_browser_js_docs` first if you haven't.
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
        let reportBug = MCP.Tool(
            name: "report_bug",
            description: """
            Report a bug, papercut, or point of friction you hit while using
            this browser's tools (BrowserJS API gaps, wrong results, flaky
            behavior, confusing docs, missing features). Call it whenever
            something doesn't work the way you expected — even if you worked
            around it. Entries are appended to a log the developer reads.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("One-line summary.")]),
                    "details": .object(["type": .string("string"), "description": .string("What you tried, what happened, what you expected. Include the code/call that misbehaved and any workaround.")]),
                ]),
                "required": .array([.string("title"), .string("details")]),
            ])
        )
        let getContext = MCP.Tool(
            name: "get_browser_context",
            description: """
            Orient yourself: returns which terminal tab you're running in (if
            any), the space it belongs to, the tabs open in that space (with
            the current one marked), the other spaces, and other windows.
            Cheap; call it at the start of a task and whenever you need a
            fresh picture of what the user has open.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )
        return [getContext, runBrowserJS, saveHelper, readHelper, getDocs, reportBug]
    }

    // MARK: - report_bug

    /// Dev-only: the bug log lives in the Wowser source checkout. Returns nil
    /// if that directory isn't present on this machine.
    private static var agentBugLogURL: URL? {
        // Real home dir (not a sandbox container), in case that ever changes.
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) else { return nil }
        let repo = URL(fileURLWithPath: home).appendingPathComponent("Documents/SW/Wowser", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return repo.appendingPathComponent("agent_reported_bugs.md")
    }

    private static func appendBugReport(title: String, details: String) throws -> Bool {
        guard let url = agentBugLogURL else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "\n\n## \(formatter.string(from: Date())) — \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(details.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } else {
            let header = "# Agent-reported bugs & friction (Wowser MCP / BrowserJS)\n"
            try Data((header + entry).utf8).write(to: url)
        }
        return true
    }

    private func handleToolCall(name: String, arguments: [String: MCP.Value]?, meta: Metadata?) async -> CallTool.Result {
        // Auth happens at the HTTP layer (path validation in MCPHTTPHandler);
        // by the time we get here, the request was authorized.
        // The originating terminal pane, if MCPHTTPHandler identified one.
        let originPaneID: String? = {
            if case .string(let s)? = meta?[BrowserJSCallOrigin.metaKey] { return s }
            return nil
        }()

        do {
            switch name {
            case "get_browser_context":
                let text = await Self.orientation(originPaneID: originPaneID.map { ID<WebContent>(raw: $0) })
                return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            case "run_browser_js":
                guard let args = arguments, case .string(let code) = args["code"] ?? .null else {
                    throw BrowserJSError.invalidArgs("code")
                }
                let result = await runtime.run(code: code, originPaneID: originPaneID)
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

            case "report_bug":
                guard let args = arguments,
                      case .string(let title) = args["title"] ?? .null,
                      case .string(let details) = args["details"] ?? .null
                else { throw BrowserJSError.invalidArgs("title, details") }
                if try Self.appendBugReport(title: title, details: details) {
                    return CallTool.Result(content: [.text("{\"ok\":true}")])
                } else {
                    return CallTool.Result(content: [.text("report_bug is unavailable on this machine (no dev checkout found)")], isError: true)
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

    private let transport: StatelessHTTPServerTransport
    private let authKey: String
    private struct State { var head: HTTPRequestHead; var body: ByteBuffer }
    private var state: State?
    /// The terminal pane this connection's client process runs in, resolved
    /// once per connection (a client keeps its connection alive across calls).
    /// Outer nil = not yet resolved; inner nil = not one of our terminals.
    private var originPaneID: ID<WebContent>??

    init(transport: StatelessHTTPServerTransport, authKey: String) {
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
            let peerPort = context.remoteAddress?.port
            Task {
                await self.handle(state: s, context: ctx, peerPort: peerPort)
            }
        }
    }

    private func handle(state: State, context: ChannelHandlerContext, peerPort: Int?) async {
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
        var bodyData: Data?
        if state.body.readableBytes > 0,
           let bytes = state.body.getBytes(at: 0, length: state.body.readableBytes) {
            bodyData = Data(bytes)
        } else {
            bodyData = nil
        }
        var isInitialize = false
        if let bodyData_ = bodyData {
            let method = Self.jsonRPCMethod(of: bodyData_)
            isInitialize = method == "initialize"
            if method == "tools/call" {
                bodyData = await stampOrigin(onto: bodyData_, peerPort: peerPort)
            }
        }
        // Strip the auth key from the path before handing to the transport,
        // so the transport sees a clean `/mcp` regardless of the URL the
        // client used. (StatelessHTTPServerTransport may route by path.)
        let req = HTTPRequest(method: state.head.method.rawValue, headers: headers, body: bodyData, path: "/mcp")
        let resp = await transport.handleRequest(req)

        if case .stream(let stream, _) = resp {
            await respondStream(context: context, version: state.head.version, status: resp.statusCode, headers: resp.headers, stream: stream)
        } else {
            var body = resp.bodyData
            if isInitialize, let body_ = body {
                body = await appendOrientation(toInitializeResponse: body_, peerPort: peerPort)
            }
            await respondSimple(context: context, version: state.head.version, status: resp.statusCode, headers: resp.headers, body: body)
        }
    }

    private static func jsonRPCMethod(of body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String
    }

    /// The terminal pane owning this connection, resolved once and cached.
    private func resolveOrigin(peerPort: Int?) async -> ID<WebContent>? {
        #if os(macOS)
        guard let peerPort, peerPort > 0 else { return nil }
        if originPaneID == nil {
            originPaneID = .some(await TerminalProcessLookup.paneID(forClientPort: UInt16(peerPort)))
        }
        if case .some(.some(let pane)) = originPaneID { return pane }
        return nil
        #else
        return nil
        #endif
    }

    /// Appends a live "what's open" orientation to `result.instructions` of an
    /// `initialize` response, so clients that surface server instructions
    /// (Claude Code puts them in its system prompt) start out oriented.
    private func appendOrientation(toInitializeResponse body: Data, peerPort: Int?) async -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var result = json["result"] as? [String: Any] else { return body }
        let origin = await resolveOrigin(peerPort: peerPort)
        let orientation = await MCPServer.orientation(originPaneID: origin)
        let base = (result["instructions"] as? String) ?? MCPServer.staticInstructions
        result["instructions"] = base + "\n\n" + orientation
        json["result"] = result
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    /// For `tools/call` requests, records which of our terminal tabs the client
    /// process lives in as `params._meta["wowser.originPane"]`. That's the
    /// only channel that survives the stateless transport into the tool handler.
    private func stampOrigin(onto body: Data, peerPort: Int?) async -> Data {
        guard let pane = await resolveOrigin(peerPort: peerPort),
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        var params = json["params"] as? [String: Any] ?? [:]
        var meta = params["_meta"] as? [String: Any] ?? [:]
        meta[BrowserJSCallOrigin.metaKey] = pane.raw
        params["_meta"] = meta
        json["params"] = params
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
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
