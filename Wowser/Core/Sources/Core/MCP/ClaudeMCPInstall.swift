import Foundation

#if os(macOS)

/// Sets up Claude Code to drive this browser: registers the Wowser MCP server
/// (`claude mcp add`, the same command Settings › MCP shows for copying) and
/// adds our recommended permission rules to `~/.claude/settings.json`.
enum ClaudeMCPInstall {
    static var serverName: String { isProd() ? "wowser" : "wowserdev" }

    /// Tools that only read, so Claude Code needn't review each call.
    /// `run_browser_js` and `save_browser_helper_file` (helpers run on every
    /// call) stay reviewed.
    static let preApprovedTools = [
        "read_browser_js",
        "get_browser_context",
        "get_browser_js_docs",
        "read_browser_helper_file",
        "report_bug",
    ]

    static func allowRules(serverName: String) -> [String] {
        preApprovedTools.map { "mcp__\(serverName)__\($0)" }
    }

    /// Returns nil on success, else a message for the user.
    static func run() async -> String? {
        let url = DefaultsKeys.mcpServerURL.stringValue()
        guard !url.isEmpty else { return "The Wowser MCP server isn't running." }
        let name = serverName
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let claude = ClaudeCodeAgent.discoverClaudeBinary() else {
                return "Couldn't find the claude command. Install Claude Code, then try again."
            }
            // The URL carries an auth key; replace any stale registration.
            _ = runProcess(claude, ["mcp", "remove", "--scope", "user", name])
            let (status, output) = runProcess(claude, ["mcp", "add", "--scope", "user", "--transport", "http", name, url])
            guard status == 0 else {
                return output.nilIfEmpty ?? "claude mcp add failed (exit code \(status))."
            }
            do {
                try applyRecommendedPermissions(serverName: name)
            } catch {
                return "Added the Wowser MCP, but couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
            }
            return nil
        }.value
    }

    // MARK: - Permissions

    static var userSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Merges our allow rules into the user's Claude Code settings, leaving
    /// everything else alone. Refuses to touch a file it can't parse.
    static func applyRecommendedPermissions(serverName: String, settingsURL: URL = userSettingsURL) throws {
        // Write through a symlink (dotfile repos) rather than replacing it.
        let target = settingsURL.resolvingSymlinksInPath()
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: target)
            if !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                settings = parsed
            }
        }
        guard let updated = settingsAddingAllowRules(settings, rules: allowRules(serverName: serverName)) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: target, options: .atomic)
    }

    /// `settings` with `rules` appended to `permissions.allow`, or nil if
    /// they're all already there.
    static func settingsAddingAllowRules(_ settings: [String: Any], rules: [String]) -> [String: Any]? {
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        let missing = rules.filter { !allow.contains($0) }
        guard !missing.isEmpty else { return nil }
        allow += missing
        permissions["allow"] = allow
        var settings = settings
        settings["permissions"] = permissions
        return settings
    }

    private static func runProcess(_ path: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    }
}

#endif
