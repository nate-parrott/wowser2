import Foundation

// Where a BrowserJS call came from, when it came from a terminal tab inside
// the browser.
//
// The MCP server is a loopback HTTP server. When `claude` (or any MCP client)
// runs in one of our terminal tabs, the client process is a descendant of that
// tab's shell, and the TCP connection it opens to us has a local port we can
// match against the socket table of that process tree. That gives us the
// originating pane with no cooperation from the client or its config.
//
// Flow:
//   MCPHTTPHandler       — resolves the peer port → pane once per connection and
//                          stamps `params._meta["tangerine.originPane"]` onto
//                          `tools/call` bodies (the SDK's server loop runs on its
//                          own task, so nothing else survives the transport hop).
//   MCPServer            — reads the meta and passes it to `BrowserJSRuntime.run`.
//   BrowserJSRuntime     — declares `__originPaneId` in JS; `__browserCall`
//                          forwards it as `__origin` on every host call.
//   BrowserJSDispatch    — binds `BrowserJSCallOrigin.paneID` for the host call.
//   Hosts                — prefer the origin pane's window and space.

enum BrowserJSCallOrigin {
    /// The terminal / agent-chat pane the current host call originated from, if known.
    @TaskLocal static var paneID: ID<WebContent>?
    /// The space the caller belongs to, for callers without a pane of their own
    /// (a chat-mode space coordinator). `paneID` wins when both are set.
    @TaskLocal static var spaceID: ID<Profile>?

    static let metaKey = "tangerine.originPane"
    static let argsKey = "__origin"
    static let argsSpaceKey = "__originSpace"
}

extension BrowserState {
    /// The window and space holding the origin pane's tab. The space can differ
    /// from the window's *current* space (the user may have swiped away), so
    /// this searches every space's per-window tab list — NOT just the visible
    /// one like `windowContaining(tabId:)` does.
    func originContext(paneID: ID<WebContent>) -> (windowID: ID<WindowState>, spaceID: ID<Profile>)? {
        guard let tabID = paneToTabMapping[paneID] else { return nil }
        for win in windowsMostRecentFirst {
            if win.tabs.contains(tabID) || win.attachedAgentTabs.contains(tabID) {
                return (win.id, win.profile)
            }
            if let space = space(containingTabId: tabID, inWindow: win.id) {
                return (win.id, space)
            }
        }
        return nil
    }

    /// Where the current BrowserJS call comes from: the origin pane's window
    /// and space, else the origin space (in a window showing it, or the most
    /// recent one). nil for callers with no origin (outside MCP clients).
    func callOriginContext() -> (windowID: ID<WindowState>, spaceID: ID<Profile>)? {
        if let pane = BrowserJSCallOrigin.paneID, let o = originContext(paneID: pane) { return o }
        if let space = BrowserJSCallOrigin.spaceID, profiles[space] != nil {
            let wins = windowsMostRecentFirst
            if let win = wins.first(where: { $0.profile == space }) ?? wins.first {
                return (win.id, space)
            }
        }
        return nil
    }

    /// The space whose tab list (or favorites) holds `tabId` within `window`.
    func space(containingTabId tabId: ID<Tab>, inWindow windowID: ID<WindowState>) -> ID<Profile>? {
        guard let win = windows[windowID] else { return nil }
        if let hit = win.perProfileData.first(where: { $0.value.tabs.contains(tabId) || $0.value.attachedAgentTabs?.contains(tabId) == true }) {
            return hit.key
        }
        if let folderTab = folderTab(containingTabId: tabId) {
            return space(containingTabId: folderTab.id, inWindow: windowID)
        }
        return profiles.values.first(where: { $0.manualFavorites.contains(tabId) || $0.autoFavorites.contains(tabId) })?.id
    }

    /// `performInSpace` targeting the current call's origin space (see
    /// `callOriginContext`), so an agent's tabs land in the space it lives in
    /// rather than whatever the user is looking at. No origin: just runs `body`.
    mutating func performInOriginSpace(window windowID: ID<WindowState>, keepSwitched: Bool, _ body: (inout BrowserState) -> Void) {
        if let o = callOriginContext() {
            performInSpace(o.spaceID, window: windowID, keepSwitched: keepSwitched, body)
        } else {
            body(&self)
        }
    }

    /// Runs `body` with `window` switched to `space`, so tab insertion and
    /// `currentTab` lookups target that space. The window stays switched only
    /// when `keepSwitched`; otherwise its current space is restored after.
    mutating func performInSpace(_ space: ID<Profile>, window windowID: ID<WindowState>, keepSwitched: Bool, _ body: (inout BrowserState) -> Void) {
        guard let previous = windows[windowID]?.profile else { body(&self); return }
        if windows[windowID]?.perProfileData[space] == nil {
            windows[windowID]?.perProfileData[space] = WindowState.PerProfileData(tabs: [])
        }
        windows[windowID]?.profile = space
        body(&self)
        if !keepSwitched {
            windows[windowID]?.profile = previous
        }
    }
}

#if os(macOS)
import Darwin

/// Maps a loopback TCP client port to the terminal pane whose shell process
/// tree owns that socket. Same-uid processes only, no entitlements needed.
enum TerminalProcessLookup {
    static func paneID(forClientPort port: UInt16) async -> ID<WebContent>? {
        let shells = await MainActor.run { shellPids() }
        guard !shells.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            for (pane, shellPid) in shells {
                for pid in descendants(of: shellPid) where ownsTCPSocket(pid: pid, localPort: port) {
                    return pane
                }
            }
            return nil
        }.value
    }

    @MainActor
    private static func shellPids() -> [(pane: ID<WebContent>, pid: pid_t)] {
        BrowserStore.shared.liveWebContentIDs.compactMap { id in
            guard let wc = BrowserStore.shared.liveWebContent(forId: id),
                  let session = wc.overlayObject as? TerminalSession,
                  let pid = session.shellPid, pid > 0 else { return nil }
            return (id, pid)
        }
    }

    /// `root` plus every transitive child, breadth-first.
    private static func descendants(of root: pid_t) -> [pid_t] {
        var out = [root]
        var i = 0
        while i < out.count {
            let parent = out[i]
            i += 1
            var buf = [pid_t](repeating: 0, count: 256)
            let n = Int(proc_listchildpids(parent, &buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
            if n > 0 { out.append(contentsOf: buf.prefix(min(n, buf.count))) }
        }
        return out
    }

    private static func ownsTCPSocket(pid: pid_t, localPort port: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size else { continue }
            guard si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            // insi_lport holds the port in network byte order (lsof applies ntohs).
            let raw = UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            if UInt16(bigEndian: raw) == port { return true }
        }
        return false
    }
}
#endif
