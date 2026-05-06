#if os(macOS)
import Foundation
import AppKit
import Combine
import Darwin

/// Lazily spawns a single shared `code serve-web` process and exposes the URL
/// it bound to. Per Q39/Q40 in the spec: one shared instance with a shared
/// `--user-data-dir`; the server keeps running once it's up so re-opening a
/// VS Code tab is instant after the first cold start.
@MainActor
final class VSCodeServerManager: ObservableObject {
    static let shared = VSCodeServerManager()

    enum Status: Equatable {
        case notStarted
        case starting
        case running(URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .notStarted

    private var process: Process?
    private var stdoutBuffer = Data()

    private init() {}

    /// Kicks off the server if it isn't already starting/running. Idempotent.
    func ensureStarted() {
        log("ensureStarted() called; current status = \(status)")
        switch status {
        case .running, .starting:
            return
        case .notStarted, .failed:
            start()
        }
    }

    /// Reset to `.notStarted` so a subsequent `ensureStarted()` will retry.
    /// Used by the "VS Code not installed" error overlay's retry button.
    func retry() {
        log("retry() called; terminating existing process if any")
        process?.terminate()
        process = nil
        stdoutBuffer = Data()
        status = .notStarted
    }

    private func start() {
        guard let codePath = VSCodeServerManager.locateCodeBinary() else {
            log("locateCodeBinary() returned nil — VS Code not found in standard paths")
            status = .failed("VS Code is not installed.")
            return
        }
        log("found code binary at \(codePath)")
        status = .starting

        reclaimPortFromOrphanedCodeServer(VSCodeConfig.serveWebPort)

        let dataDir = vscodeUserDataDir()
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            log("user-data-dir = \(dataDir.path)")
        } catch {
            log("failed to create user-data-dir at \(dataDir.path): \(error)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: codePath)
        p.arguments = [
            "serve-web",
            "--host", VSCodeConfig.serveWebHost,
            "--port", String(VSCodeConfig.serveWebPort),
            "--without-connection-token",
            "--accept-server-license-terms",
            "--server-data-dir", dataDir.path,
        ]
        log("launching: \(codePath) \((p.arguments ?? []).joined(separator: " "))")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // Read incrementally; the `Web UI available at http://127.0.0.1:<port>`
        // line shows up on stdout once the server is ready.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.handleOutput(data) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.log("process terminated; exit=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue) status=\(self.status)")
                if case .running = self.status { return } // server died after coming up — leave URL stale; next tab will note the dead URL
                if proc.terminationStatus != 0 {
                    self.status = .failed("`code serve-web` exited with status \(proc.terminationStatus). VS Code may need an update.")
                } else {
                    // exited cleanly before we ever saw the URL — treat as failure so UI doesn't sit on "Starting…" forever
                    self.status = .failed("`code serve-web` exited before reporting a URL.")
                }
            }
        }

        do {
            try p.run()
            log("process started; pid=\(p.processIdentifier)")
            self.process = p
        } catch {
            log("Process.run() threw: \(error)")
            status = .failed("Failed to launch VS Code: \(error.localizedDescription)")
        }
    }

    private func handleOutput(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        if let chunkStr = String(data: chunk, encoding: .utf8) {
            // log raw output line-by-line so we can see download progress, errors, etc.
            for line in chunkStr.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                log("stdout/err: \(line)")
            }
        } else {
            log("stdout/err: <\(chunk.count) bytes non-utf8>")
        }
        guard let s = String(data: stdoutBuffer, encoding: .utf8) else { return }
        if let url = VSCodeServerManager.parseServeWebURL(from: s) {
            log("parsed serve-web URL: \(url)")
            status = .running(url)
            stdoutBuffer = Data()
        }
    }

    private func log(_ msg: @autoclosure () -> String) {
        print("[VSCodeServer] \(msg())")
    }

    /// If our fixed port is already bound by an orphaned `code serve-web`
    /// (left over from a prior Wowser run that didn't exit cleanly), kill
    /// it so we can rebind. We're conservative: only kill processes whose
    /// command line clearly identifies them as a VS Code server. Anything
    /// else, we leave alone and let the launch fail loudly.
    private func reclaimPortFromOrphanedCodeServer(_ port: Int) {
        let pids = Self.pidsListening(onPort: port)
        guard !pids.isEmpty else { return }
        var killed: [pid_t] = []
        for pid in pids {
            let cmd = Self.commandLine(forPID: pid) ?? ""
            if Self.looksLikeCodeServer(cmd) {
                log("port \(port) held by orphaned code-server pid=\(pid) — killing. cmd=\(cmd)")
                if kill(pid, SIGTERM) == 0 {
                    killed.append(pid)
                } else {
                    log("kill(\(pid), SIGTERM) failed errno=\(errno)")
                }
            } else {
                log("port \(port) held by pid=\(pid) which is NOT a code-server — leaving alone. cmd=\(cmd)")
            }
        }
        if !killed.isEmpty {
            Self.waitForPIDsToExit(killed, timeout: 1.5)
        }
    }

    private static func looksLikeCodeServer(_ cmd: String) -> Bool {
        // Match either the user-visible `code serve-web` invocation or the
        // forked `code-tunnel`/`code-server` worker. Be permissive but specific.
        let lower = cmd.lowercased()
        return lower.contains("serve-web")
            || (lower.contains("code") && lower.contains("visual studio code"))
            || lower.contains("code-tunnel")
            || lower.contains("code-server")
    }

    private static func pidsListening(onPort port: Int) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: { $0.isNewline }).compactMap { pid_t($0) }
    }

    private static func commandLine(forPID pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waitForPIDsToExit(_ pids: [pid_t], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let alive = pids.filter { kill($0, 0) == 0 }
            if alive.isEmpty { return }
            usleep(50_000)
        }
    }

    static func parseServeWebURL(from text: String) -> URL? {
        // Look for the first `http://127.0.0.1:<port>` substring.
        let pattern = #"http://127\.0\.0\.1:\d+(/[^\s"']*)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[r]))
    }

    static func locateCodeBinary() -> String? {
        let candidates = [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code",
            "\(NSHomeDirectory())/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private func vscodeUserDataDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "Wowser"
        return base.appendingPathComponent(bundle).appendingPathComponent("vscode-user-data\(dataDirSuffix())")
    }
}
#endif
