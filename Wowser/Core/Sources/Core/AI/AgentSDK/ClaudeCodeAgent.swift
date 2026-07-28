import Foundation

#if os(macOS)

// An `Agent` backed by the Claude Code CLI (the Claude Agent SDK harness),
// spawned as a long-lived subprocess speaking the stream-json protocol:
//
//   claude -p --verbose --input-format stream-json --output-format stream-json
//
// Messages go in as NDJSON user envelopes on stdin; assistant/tool/result
// messages come back as NDJSON on stdout. Host tools are exposed via an
// in-process "sdk" MCP server: the CLI routes MCP JSON-RPC (initialize,
// tools/list, tools/call) to us as `control_request` messages with subtype
// `mcp_message` on stdout, and we answer with `control_response` on stdin —
// no second process, and tool outputs may include images.
public actor ClaudeCodeAgent: Agent {

    public struct Configuration: Sendable {
        public var model: String?
        /// Reasoning effort: "low" | "medium" | "high" | "xhigh" | "max".
        public var effort: String?
        public var systemPrompt: String?
        public var appendSystemPrompt: String?
        /// Give the agent the harness's filesystem/shell tools (Read, Write,
        /// Edit, Bash, Glob, Grep, ...). Off by default: a browser-embedded
        /// agent normally acts through its BrowserJS tools instead.
        public var enableFileSystemTools: Bool
        public var permissionMode: String
        public var maxTurns: Int?
        public var workingDirectory: URL?
        /// Host tools served to the agent over the in-process MCP bridge.
        public var tools: [AgentToolDefinition]
        /// Per-turn timeout. The turn is interrupted and fails on expiry.
        public var turnTimeout: TimeInterval
        /// Explicit path to the `claude` binary; nil = auto-discover.
        public var claudeBinaryPath: String?
        /// Resume this CLI session instead of starting a new conversation.
        public var resumeSessionID: String?

        public init(
            model: String? = nil,
            effort: String? = nil,
            systemPrompt: String? = nil,
            appendSystemPrompt: String? = nil,
            enableFileSystemTools: Bool = false,
            permissionMode: String = "bypassPermissions",
            maxTurns: Int? = nil,
            workingDirectory: URL? = nil,
            tools: [AgentToolDefinition] = [],
            turnTimeout: TimeInterval = 60 * 10,
            claudeBinaryPath: String? = nil,
            resumeSessionID: String? = nil
        ) {
            self.model = model; self.effort = effort
            self.systemPrompt = systemPrompt; self.appendSystemPrompt = appendSystemPrompt
            self.enableFileSystemTools = enableFileSystemTools
            self.permissionMode = permissionMode; self.maxTurns = maxTurns
            self.workingDirectory = workingDirectory; self.tools = tools
            self.turnTimeout = turnTimeout; self.claudeBinaryPath = claudeBinaryPath
            self.resumeSessionID = resumeSessionID
        }
    }

    static let mcpServerName = "wowser"

    private let config: Configuration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrData = Data()
    private var isShutDown = false

    public private(set) var sessionID: String?

    // In-flight turns, oldest first. The CLI accepts messages while it is
    // working and answers them in order, so we deliver immediately and match
    // each `result` to the oldest pending turn rather than serializing sends.
    private struct PendingTurn {
        let id: UUID
        let continuation: CheckedContinuation<AgentTurnResult, Error>
        var timeoutTask: Task<Void, Never>?
    }
    private var pendingTurns: [PendingTurn] = []
    /// Set when we've asked the CLI to stop; the turn it kills reports a
    /// generic execution error, which we translate into a clean stop.
    private var interruptRequested = false

    // Event broadcast
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    // MARK: - Agent

    /// Sends immediately, even while an earlier turn is still running — the
    /// CLI queues messages and answers them in order, so this is how you steer
    /// a working agent ("actually, do X instead") without waiting for it.
    public func send(_ message: AgentUserMessage) async throws -> AgentTurnResult {
        if isShutDown { throw AgentSDKError.shutDown }
        try ensureStarted()

        var content: [[String: Any]] = []
        for image in message.images {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": image.mime, "data": image.data],
            ])
        }
        content.append(["type": "text", "text": message.text])
        try writeLine([
            "type": "user",
            "message": ["role": "user", "content": content],
        ])

        let turnID = UUID()
        let timeout = config.turnTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timeOutTurn(turnID)
            }
            pendingTurns.append(PendingTurn(id: turnID, continuation: continuation, timeoutTask: timeoutTask))
        }
    }

    public func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    public func interrupt() {
        guard process?.isRunning == true, !pendingTurns.isEmpty else { return }
        interruptRequested = true
        try? writeLine([
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ])
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        failAllTurns(with: AgentSDKError.shutDown)
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdoutTask?.cancel()
        emit(.terminated)
        for (_, c) in eventContinuations { c.finish() }
        eventContinuations.removeAll()
    }

    // MARK: - Process lifecycle

    private func ensureStarted() throws {
        if let process, process.isRunning { return }
        guard !isShutDown else { throw AgentSDKError.shutDown }

        guard let binary = config.claudeBinaryPath ?? Self.discoverClaudeBinary() else {
            throw AgentSDKError.binaryNotFound
        }

        var args = [
            "-p", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--strict-mcp-config",
            "--permission-mode", config.permissionMode,
        ]
        if let resume = config.resumeSessionID ?? sessionID { args += ["--resume", resume] }
        if let model = config.model { args += ["--model", model] }
        if let effort = config.effort { args += ["--effort", Self.normalizeEffort(effort)] }
        if let system = config.systemPrompt { args += ["--system-prompt", system] }

        var appendPieces: [String] = []
        if let append = config.appendSystemPrompt { appendPieces.append(append) }
        if !config.enableFileSystemTools {
            // Without the built-in tools the model still believes it has
            // Read/Bash/Glob, and writes tool-call syntax into its visible text
            // when a task needs them. Tell it what it actually has.
            args += ["--tools", ""]
            let available = config.tools.isEmpty
                ? "You have NO tools at all in this session."
                : "The only tools you have are: \(config.tools.map(\.name).joined(separator: ", "))."
            appendPieces.append("""
            \(available) You have no filesystem, shell, editing, or search tools. \
            NEVER write tool-call syntax (such as function_calls or invoke blocks) \
            into your response text — it does not invoke anything and is shown to \
            the user verbatim. If a request needs a capability you don't have, say \
            so plainly and do what you can with the tools listed above.
            """)
        }
        if !appendPieces.isEmpty {
            args += ["--append-system-prompt", appendPieces.joined(separator: "\n\n")]
        }
        if let maxTurns = config.maxTurns { args += ["--max-turns", String(maxTurns)] }

        var allowed: [String] = []
        if !config.tools.isEmpty {
            let mcpConfig: [String: Any] = [
                "mcpServers": [Self.mcpServerName: ["type": "sdk", "name": Self.mcpServerName]],
            ]
            let data = try JSONSerialization.data(withJSONObject: mcpConfig)
            args += ["--mcp-config", String(data: data, encoding: .utf8)!]
            allowed += config.tools.map { "mcp__\(Self.mcpServerName)__\($0.name)" }
        }
        if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.currentDirectoryURL = config.workingDirectory ?? Self.defaultWorkingDirectory()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")  // don't look like a nested session
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Ordered stdout delivery: readabilityHandler yields into an
        // AsyncStream that the actor consumes serially.
        let (stdoutStream, stdoutContinuation) = AsyncStream.makeStream(of: Data.self)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
            } else {
                stdoutContinuation.yield(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { await self?.appendStderr(data) }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { await self?.processDied(exitCode: code) }
        }

        try proc.run()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting

        stdoutTask = Task { [weak self] in
            var buffer = Data()
            for await chunk in stdoutStream {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !lineData.isEmpty else { continue }
                    await self?.handleStdoutLine(lineData)
                }
            }
        }
    }

    private func appendStderr(_ data: Data) {
        stderrData.append(data)
        if stderrData.count > 64 * 1024 { stderrData = stderrData.suffix(32 * 1024) }
    }

    private func processDied(exitCode: Int32) {
        guard !isShutDown else { return }
        process = nil
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let message = "agent process exited (code \(exitCode))" + (stderr.isEmpty ? "" : ": \(stderr.suffix(2000))")
        failAllTurns(with: AgentSDKError.turnFailed(message))
        emit(.failed(message))
    }

    private func timeOutTurn(_ id: UUID) {
        guard let idx = pendingTurns.firstIndex(where: { $0.id == id }) else { return }
        let turn = pendingTurns.remove(at: idx)
        interrupt()
        turn.continuation.resume(throwing: AgentSDKError.timeout)
    }

    /// Resolves the oldest in-flight turn; results arrive in send order.
    private func completeOldestTurn(with result: AgentTurnResult) {
        guard !pendingTurns.isEmpty else { return }
        let turn = pendingTurns.removeFirst()
        turn.timeoutTask?.cancel()
        turn.continuation.resume(returning: result)
    }

    private func failAllTurns(with error: Error) {
        let turns = pendingTurns
        pendingTurns.removeAll()
        for turn in turns {
            turn.timeoutTask?.cancel()
            turn.continuation.resume(throwing: error)
        }
    }

    // MARK: - Incoming messages

    private func handleStdoutLine(_ data: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String {
                sessionID = sid
                emit(.started(sessionID: sid))
            }
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    emit(.assistantText(block["text"] as? String ?? ""))
                case "thinking":
                    emit(.thinking(block["thinking"] as? String ?? ""))
                case "tool_use":
                    let name = block["name"] as? String ?? "?"
                    let input = block["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    emit(.toolUse(name: name, inputJSON: input.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"))
                default: break
                }
            }
        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                emit(.toolResult(text: Self.flattenToolResultContent(block["content"]),
                                 isError: block["is_error"] as? Bool ?? false))
            }
        case "result":
            var result = AgentTurnResult(
                text: obj["result"] as? String ?? "",
                isError: (obj["is_error"] as? Bool ?? false) || (obj["subtype"] as? String != "success"),
                stopReason: obj["stop_reason"] as? String ?? obj["subtype"] as? String,
                costUSD: obj["total_cost_usd"] as? Double,
                sessionID: obj["session_id"] as? String
            )
            // A turn we stopped on purpose comes back as a generic execution
            // error with no text. Report it as a stop, not a failure.
            if interruptRequested {
                interruptRequested = false
                result.isError = false
                result.stopReason = "interrupted"
                if result.text.isEmpty { result.text = "(stopped)" }
                emit(.interrupted)
            }
            emit(.turnCompleted(result))
            completeOldestTurn(with: result)
        case "control_request":
            await handleControlRequest(obj)
        default:
            break  // stream_event, rate_limit_event, control_response, ...
        }
    }

    private static func flattenToolResultContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Control protocol (in-process MCP server + permissions)

    private func handleControlRequest(_ obj: [String: Any]) async {
        guard let requestID = obj["request_id"] as? String,
              let request = obj["request"] as? [String: Any],
              let subtype = request["subtype"] as? String else { return }

        switch subtype {
        case "mcp_message":
            guard let rpc = request["message"] as? [String: Any] else { return }
            if let response = await handleMCPMessage(rpc) {
                try? writeLine([
                    "type": "control_response",
                    "response": [
                        "subtype": "success",
                        "request_id": requestID,
                        "response": ["mcp_response": response],
                    ],
                ])
            }
        case "can_use_tool":
            // We only reach here for tools not covered by allowedTools; allow.
            try? writeLine([
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": requestID,
                    "response": [
                        "behavior": "allow",
                        "updatedInput": request["input"] as? [String: Any] ?? [:],
                    ],
                ],
            ])
        default:
            try? writeLine([
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestID,
                    "error": "unsupported control request: \(subtype)",
                ],
            ])
        }
    }

    /// Handles one MCP JSON-RPC message. Every message — even notifications —
    /// must be answered: the CLI awaits a control_response per mcp_message.
    private func handleMCPMessage(_ rpc: [String: Any]) async -> [String: Any]? {
        let method = rpc["method"] as? String ?? ""
        let rpcID = rpc["id"]
        if method.hasPrefix("notifications/") {
            return ["jsonrpc": "2.0", "result": [String: Any]()]
        }
        guard let rpcID else { return ["jsonrpc": "2.0", "result": [String: Any]()] }

        func response(result: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": rpcID, "result": result]
        }

        switch method {
        case "initialize":
            let params = rpc["params"] as? [String: Any]
            return response(result: [
                "protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.mcpServerName, "version": "1.0.0"],
            ])
        case "ping":
            return response(result: [:])
        case "tools/list":
            let tools: [[String: Any]] = config.tools.map { tool in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any]
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": schema ?? ["type": "object"],
                ]
            }
            return response(result: ["tools": tools])
        case "tools/call":
            let params = rpc["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            guard let tool = config.tools.first(where: { $0.name == name }) else {
                return ["jsonrpc": "2.0", "id": rpcID,
                        "error": ["code": -32602, "message": "unknown tool: \(name)"]]
            }
            let argsJSON: String
            if let args = params?["arguments"], let data = try? JSONSerialization.data(withJSONObject: args) {
                argsJSON = String(data: data, encoding: .utf8) ?? "{}"
            } else {
                argsJSON = "{}"
            }
            let output = await tool.handler(argsJSON)
            var content: [[String: Any]] = [["type": "text", "text": output.text]]
            for image in output.images {
                content.append(["type": "image", "data": image.data, "mimeType": image.mime])
            }
            return response(result: ["content": content, "isError": output.isError])
        default:
            return ["jsonrpc": "2.0", "id": rpcID,
                    "error": ["code": -32601, "message": "method not found: \(method)"]]
        }
    }

    // MARK: - Output

    private func writeLine(_ obj: [String: Any]) throws {
        guard let handle = stdinHandle else { throw AgentSDKError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func emit(_ event: AgentEvent) {
        for (_, c) in eventContinuations { c.yield(event) }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    static func normalizeEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "med", "mid": return "medium"
        case "hi": return "high"
        case "lo": return "low"
        default: return effort.lowercased()
        }
    }

    // MARK: - Binary discovery

    public static func discoverClaudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to the user's login shell PATH.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }
        return nil
    }

    private static func defaultWorkingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WowserAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The default `AgentProvider` on macOS: agents backed by the `claude` CLI.
public struct ClaudeCodeAgentProvider: AgentProvider {
    public let id = "claude-code"

    public init() {}

    public var isAvailable: Bool {
        ClaudeCodeAgent.discoverClaudeBinary() != nil
    }

    public func makeAgent(_ spec: AgentSpec) -> any Agent {
        ClaudeCodeAgent(configuration: .init(
            model: spec.model,
            effort: spec.effort,
            systemPrompt: spec.systemPrompt,
            appendSystemPrompt: spec.appendSystemPrompt,
            enableFileSystemTools: spec.enableFileSystemTools,
            workingDirectory: spec.workingDirectory,
            tools: spec.tools,
            resumeSessionID: spec.resumeSessionID
        ))
    }
}

#endif
