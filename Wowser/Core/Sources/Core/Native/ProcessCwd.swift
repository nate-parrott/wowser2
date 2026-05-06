#if os(macOS)
import Darwin

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

    /// Whether the shell itself currently owns the PTY's foreground process
    /// group (i.e. no child app like vim or claude is running). True when
    /// `tcgetpgrp` matches `shellPid` or returns no current group.
    static func isShellInForeground(masterFd fd: Int32, shellPid: pid_t) -> Bool {
        let pgrp = tcgetpgrp(fd)
        return pgrp <= 0 || pgrp == shellPid
    }
}
#endif
