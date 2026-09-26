//
//  TerminalActions.swift
//  Core
//
//  Created by Nate Parrott on 9/18/26.
//

import Foundation

#if os(macOS)
/// Answers "does this omnibox query look like a shell command?" so the
/// searcher can offer a "run in terminal" row.
///
/// At app launch (and every 6h) a low-priority task refreshes the set of
/// command names: executables on `PATH` (plus the usual Homebrew/user bins),
/// the user's zsh aliases and functions, and a fixed list of shell builtins.
/// Until the first refresh lands, every query is `.unlikely`.
final class TerminalCommandCache {
    static let shared = TerminalCommandCache()

    private let lock = NSLock()
    private var commands = Set<String>()
    private var lastRefresh: Date?
    private var refreshing = false
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// Shell builtins and keywords that aren't files on PATH.
    private static let builtins: Set<String> = [
        "cd", "pwd", "echo", "export", "source", "alias", "unalias", "exit", "set", "unset",
        "which", "type", "history", "jobs", "fg", "bg", "kill", "wait", "read", "eval", "exec",
        "printf", "test", "true", "false", "let", "local", "return", "shift", "trap", "ulimit",
        "umask", "pushd", "popd", "dirs", "hash", "command", "builtin", "time", "times",
        "for", "while", "if", "case", "function", "select", "until", "clear", "sudo", "env",
    ]

    /// Commands the user runs bare often enough that the single word alone is
    /// a strong signal (vs. "cat", "top", "man", which are also plain words).
    private static let likelyBare: Set<String> = [
        "cd", "ls", "pwd", "git", "claude", "vim", "nvim", "vi", "htop", "top", "brew", "npm",
        "npx", "yarn", "pnpm", "swift", "xcodebuild", "cargo", "make", "python3", "node", "ssh",
        "ll", "la", "tmux", "docker", "kubectl", "gh", "bun", "deno", "pip3", "irb", "psql",
    ]

    private init() {}

    /// Kick off (or re-kick, once stale) the background scan.
    func refreshIfNeeded() {
        lock.lock()
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        guard stale, !refreshing else { lock.unlock(); return }
        refreshing = true
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            let found = Self.scanCommands()
            self?.store(found.union(Self.builtins))
        }
    }

    private func store(_ found: Set<String>) {
        lock.lock()
        commands = found
        lastRefresh = Date()
        refreshing = false
        lock.unlock()
    }

    func isTerminalCommand(_ query: String) -> TerminalCommandLikelihood {
        refreshIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return .unlikely }
        var words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return .unlikely }

        // "sudo git ..." / "time make" — judge the wrapped command.
        while words.count > 1, ["sudo", "time", "env", "nohup"].contains(words[0]) {
            words.removeFirst()
        }
        let head = words[0]

        // "./build.sh" or "bin/foo": a real executable relative to home.
        if head.contains("/") {
            let path = (head as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? .likely : .unlikely
        }

        lock.lock()
        let known = commands.contains(head)
        lock.unlock()
        guard known else { return .unlikely }

        let hasFlags = words.dropFirst().contains(where: { $0.hasPrefix("-") })
        let hasShellSyntax = words.dropFirst().contains(where: { ["|", "&&", "||", ">", ">>", "<", ";"].contains($0) })
            || trimmed.contains("|") || trimmed.contains("&&") || trimmed.contains(" > ")
        if hasFlags || hasShellSyntax { return .likely }
        if words.count == 1 { return Self.likelyBare.contains(head) ? .likely : .possibly }
        // Command plus plain args ("git status", "cat foo"): likely for the
        // common dev tools, possible otherwise.
        return Self.likelyBare.contains(head) ? .likely : .possibly
    }

    // MARK: - Scanning

    private static func scanCommands() -> Set<String> {
        var names = Set<String>()
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin",
            "/opt/homebrew/sbin", home + "/.local/bin", home + "/.cargo/bin", home + "/bin",
            home + "/.bun/bin", home + "/.npm-global/bin",
        ]
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in dirs where seen.insert(dir).inserted {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where !item.hasPrefix(".") {
                names.insert(item)
            }
        }
        names.formUnion(shellAliasesAndFunctions())
        return names
    }

    /// Names defined by the user's interactive zsh config (aliases + functions).
    private static func shellAliasesAndFunctions() -> Set<String> {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-ic", "alias; print -l ${(k)functions}"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(5)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if proc.isRunning, Date() > deadline { proc.terminate() }
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            // alias lines: "name=value" (zsh omits the "alias " prefix); function
            // names print one per line.
            let name = line.split(separator: "=", maxSplits: 1).first.map(String.init) ?? String(line)
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty, !cleaned.hasPrefix("_"), !cleaned.contains(" ") {
                names.insert(cleaned)
            }
        }
        return names
    }
}
#endif

enum TerminalCommandLikelihood {
    case likely, possibly, unlikely
}
