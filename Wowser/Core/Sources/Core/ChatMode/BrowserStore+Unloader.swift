import Foundation
import WebKit

// LRU unloading of background tabs in chat-mode spaces.
//
// A chat-mode space accumulates tabs indefinitely (every card in the thread
// is one), so we can't keep them all live. Periodically, for each window
// showing a chat-mode space, the least-recently-used web tabs beyond a small
// live budget have their WebContent dropped. The tab stays in the thread as a
// (dimmed) card and reloads from its URL when shown again.
//
// Never unloaded: the current tab, pinned/favorite tabs, native tabs
// (terminals own a PTY; agent tabs own a session), pip tabs, ghost tabs and
// tabs an agent holds a lease on, tabs touched in the last few minutes, and
// pages whose `beforeunload` handler objects (unsaved form, in-progress
// upload) — we ask the page first.

extension BrowserState {
    /// Panes eligible for unloading right now, oldest first.
    func chatModeUnloadCandidates(livePaneIDs: Set<ID<WebContent>>, now: Date, keepLive: Int, minIdle: TimeInterval) -> [ID<WebContent>] {
        var out: [ID<WebContent>] = []
        for win in windows.values {
            guard profiles[win.profile]?.isChatMode == true else { continue }
            let liveTabs: [(tab: Tab, panes: [Pane])] = win.tabs.compactMap { tabID in
                guard let tab = tabs[tabID], tabID != win.currentTab, !tab.isPip else { return nil }
                let panes = tab.panes.asArray.filter { livePaneIDs.contains($0.id) }
                return panes.isEmpty ? nil : (tab, panes)
            }
            .sorted { $0.tab.lastAccessed > $1.tab.lastAccessed }
            for (tab, panes) in liveTabs.dropFirst(keepLive) {
                guard now.timeIntervalSince(tab.lastAccessed) > minIdle else { continue }
                for pane in panes {
                    if pane.isGhost { continue }
                    if let until = pane.agentActiveUntil, until > now { continue }
                    guard let url = pane.info.url else { continue }
                    if NativePageKey(url: url) != nil { continue }
                    if url.scheme != "http" && url.scheme != "https" { continue }
                    out.append(pane.id)
                }
            }
        }
        return out
    }
}

extension BrowserStore {
    static let unloaderKeepLive = 6
    static let unloaderMinIdle: TimeInterval = 5 * 60

    /// Start the periodic sweep. Cheap when no space is in chat mode.
    func setupChatModeUnloader() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.unloadOldChatModeTabs() }
        }
    }

    @MainActor
    func unloadOldChatModeTabs() {
        let live = Set(liveWebContentIDs)
        let candidates = model.chatModeUnloadCandidates(livePaneIDs: live, now: Date(), keepLive: Self.unloaderKeepLive, minIdle: Self.unloaderMinIdle)
        guard !candidates.isEmpty else { return }
        Task { @MainActor in
            for paneID in candidates {
                guard let wc = liveWebContent(forId: paneID) else { continue }
                if await Self.pageObjectsToUnload(wc) { continue }
                unloadWebContent(forId: paneID)
                modify { st in
                    st.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in pane.unloaded = true }
                }
            }
        }
    }

    /// Ask the page whether it wants to block navigation away: fire a
    /// synthetic `beforeunload` at `addEventListener` handlers and call an
    /// `onbeforeunload` property handler directly (the legacy way pages set
    /// `returnValue` to a string). Any objection means we leave it alone.
    @MainActor
    private static func pageObjectsToUnload(_ wc: WebContent) async -> Bool {
        guard let webview = wc.wkWebview else { return false }
        let js = """
        (() => {
            try {
                const e = new Event('beforeunload', { cancelable: true });
                window.dispatchEvent(e);
                if (e.defaultPrevented) return true;
                if (typeof e.returnValue === 'string' && e.returnValue !== '') return true;
                if (typeof window.onbeforeunload === 'function') {
                    const r = window.onbeforeunload(e);
                    if (r !== undefined && r !== null && r !== '') return true;
                    if (e.defaultPrevented) return true;
                }
                return false;
            } catch (err) { return false; }
        })()
        """
        let result = try? await webview.evalReturningValue(js)
        return (result as? Bool) ?? false
    }
}
