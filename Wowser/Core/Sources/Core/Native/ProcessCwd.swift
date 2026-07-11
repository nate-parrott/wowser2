#if os(macOS)
import Darwin
import Foundation

/// Helpers for reading a process's working directory from the kernel via
/// `proc_pidinfo`. Used by the terminal overlay to track cwd without
/// shell-side cooperation (no OSC 7, no rc-file injection).
enum ProcessCwd {
    /// Read a process's cwd. Returns nil if the pid is invalid, has exited,
    /// or the call fails. For descendant processes of an unsandboxed app
    /// this never requires entitlements.
    static func cwd(forPid pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Returns the pid whose cwd best represents "the user's current
    /// directory" for a given PTY: the foreground process group leader if
    /// one exists, otherwise `fallback` (typically the shell pid).
    static func foregroundPid(forMasterFd fd: Int32, fallback: pid_t) -> pid_t {
        let pgrp = tcgetpgrp(fd)
        return pgrp > 0 ? pgrp : fallback
    }

    /// The PTY's foreground process group when it is *not* the shell — i.e. a
    /// child app (vim, npm, caffeinate) currently owns the terminal. nil when
    /// the user is sitting at the prompt.
    static func foregroundChildPgid(masterFd fd: Int32, shellPid: pid_t) -> pid_t? {
        let pgrp = tcgetpgrp(fd)
        guard pgrp > 0, pgrp != shellPid else { return nil }
        return pgrp
    }

    /// A short, human-readable rendering of a process's command line, suitable
    /// for a tab title: `"npm run dev"`, `"caffeinate -d"`, `"vim README.md"`.
    /// Returns nil if the pid is gone or its argv can't be read.
    static func displayCommand(forPid pid: pid_t) -> String? {
        guard var args = commandLine(forPid: pid), !args.isEmpty else { return nil }

        // Unwrap interpreter shims. `npm run dev` really execs
        // `node /usr/local/bin/npm run dev` (npm's shebang is `env node`), so
        // the raw argv[0] would read as "node". Only unwrap when the next
        // entry is a script path rather than a flag, so `python3 -m http.server`
        // survives intact.
        while args.count > 1,
              interpreters.contains(lastPathComponent(args[0])),
              !args[1].hasPrefix("-") {
            args.removeFirst()
        }

        let head = lastPathComponent(args[0])
        guard !head.isEmpty else { return nil }
        // npm rewrites its own argv to ["npm run dev", "", "", ""] — a program
        // is free to blank out trailing entries, so drop the empties rather
        // than joining them into trailing whitespace.
        let rest = args.dropFirst().filter { !$0.isEmpty }.map(abbreviateArg)
        return truncateForTitle(([head] + rest).joined(separator: " "))
    }

    /// argv of a process, read via `KERN_PROCARGS2`. Readable without
    /// entitlements for processes owned by the same uid — which covers every
    /// descendant of our PTY.
    ///
    /// Buffer layout: `int argc`, the NUL-terminated exec path, NUL padding,
    /// then `argc` NUL-separated argv entries (followed by the environment,
    /// which we ignore).
    static func commandLine(forPid pid: pid_t) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > headerSize else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > headerSize else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<headerSize]) }
        guard argc > 0 else { return nil }

        var i = headerSize
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        while i < size, args.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1 // step over the NUL
        }
        return args.isEmpty ? nil : args
    }

    /// Programs that exec a script and would otherwise mask its name.
    private static let interpreters: Set<String> = [
        "env", "node", "nodejs", "bun", "deno",
        "python", "python2", "python3", "ruby", "perl", "php",
        "sh", "bash", "zsh", "dash",
    ]

    private static func lastPathComponent(_ s: String) -> String {
        (s as NSString).lastPathComponent
    }

    /// Long paths eat the tab strip; show just the leaf. `-d`, `dev`, `60` and
    /// other short args pass through untouched.
    private static func abbreviateArg(_ arg: String) -> String {
        guard arg.contains("/"), arg.count > 16 else { return arg }
        return lastPathComponent(arg)
    }

    private static func truncateForTitle(_ s: String, limit: Int = 44) -> String {
        guard s.count > limit else { return s }
        return s.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
#endif
