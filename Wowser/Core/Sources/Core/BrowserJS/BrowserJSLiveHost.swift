import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif

// BrowserStore-backed implementation of BrowserJSHost.
//
// "tabId" maps to ID<WebContent>.raw (per-pane). "windowId" maps to
// ID<WindowState>.raw.
public final class BrowserJSLiveHost: BrowserJSHost, @unchecked Sendable {
    public static let shared = BrowserJSLiveHost()

    public init() {}

    // MARK: - Tabs

    public func tabsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSTabInfo] {
        try await main {
            let state = BrowserStore.shared.model
            let targetWindow = self.resolveWindowID(windowId, state: state)
            let space = try spaceId.map { try self.resolveSpaceID($0, state: state) }
            var out: [BrowserJSTabInfo] = []
            for (winID, win) in state.windows {
                if let targetWindow, winID != targetWindow { continue }
                let space = space ?? win.profile
                for (idx, tabID) in self.tabIDs(inWindow: win, space: space).enumerated() {
                    guard let tab = state.tabs[tabID] else { continue }
                    for pane in tab.panes {
                        out.append(self.tabInfo(forPane: pane, tab: tab, windowID: winID, indexInWindow: idx, spaceID: space, state: state))
                    }
                }
            }
            return out
        }
    }

    public func tabsOpen(url urlStr: String, background: Bool, windowId: String?) async throws -> String {
        return try await openTabInternal(urlStr: urlStr, background: background, ghost: false, windowId: windowId)
    }

    public func tabsOpenGhost(url urlStr: String, windowId: String?) async throws -> String {
        return try await openTabInternal(urlStr: urlStr, background: true, ghost: true, windowId: windowId)
    }

    private func openTabInternal(urlStr: String, background: Bool, ghost: Bool, windowId: String?) async throws -> String {
        guard let url = URL(string: urlStr) else { throw BrowserJSError.invalidArgs("url") }
        return try await mainAsync { @MainActor in
            let state = BrowserStore.shared.model
            let win: ID<WindowState>
            if let resolved = self.resolveWindowID(windowId, state: state) {
                win = resolved
            } else {
                win = self.preferredCurrentWindow(state: state) ?? self.ensureWindow()
            }

            var paneID: ID<WebContent>!
            BrowserStore.shared.modify { st in
                // A foreground open switches the window to the caller's space;
                // a background one lands there without disturbing the user.
                st.performInOriginSpace(window: win, keepSwitched: !background) { st in
                    let pid = ID<WebContent>.assign()
                    paneID = pid
                    var pane = Pane(id: pid, info: .init(url: url))
                    pane.isGhost = ghost
                    if ghost { pane.agentActiveUntil = Date().addingTimeInterval(BrowserState.agentUseLeaseSeconds) }
                    let tab = Tab(id: .assign(), panes: [pane])
                    let loc = st.spawnInsertionIndex(window: win, spawningPaneID: BrowserJSCallOrigin.paneID)
                    st.insertTab(tab, location: loc, inWindow: win)
                    if !background {
                        st.activate(tabId: tab.id, in: win)
                    }
                }
            }
            // Ghost panes need a live WebContent so the page actually loads in
            // the background. Materialize it eagerly.
            if ghost, let wc = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: win) {
                #if os(macOS)
                // Park it in the offscreen stage so it lays out at a real
                // viewport and can be screenshotted / clicked while hidden.
                AgentStageWindow.shared.ensureRenderable(wc.view)
                #endif
                // Don't hand the id back while the webview is still showing the
                // initial about:blank.
                try await Self.waitForInitialCommit(wc)
            }
            return paneID.raw
        }
    }

    public func tabsUse(id: String, minutes: Double?) async throws -> Double {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            let mins = minutes ?? (BrowserState.agentUseLeaseSeconds / 60)
            if mins <= 0 {
                var ok = false
                BrowserStore.shared.modify { st in ok = st.setAgentUse(paneID: pid, until: nil) }
                guard ok else { throw BrowserJSError.tabNotFound(id) }
                #if os(macOS)
                if let wc = BrowserStore.shared.liveWebContent(forId: pid) { AgentStageWindow.shared.unmount(wc.view) }
                #endif
                return 0
            }
            let until = Date().addingTimeInterval(mins * 60)
            var ok = false
            BrowserStore.shared.modify { st in ok = st.setAgentUse(paneID: pid, until: until) }
            guard ok else { throw BrowserJSError.tabNotFound(id) }
            // Make sure it's live and rendering — a lease that doesn't is a lie.
            let wc = try Self.liveWebContent(forTabID: id)
            #if os(macOS)
            AgentStageWindow.shared.ensureRenderable(wc.view)
            #endif
            return until.timeIntervalSince1970
        }
    }

    /// Implicit lease: any agent interaction with a pane counts as "using" it.
    @MainActor
    private func touchAgentUse(_ pid: ID<WebContent>) {
        BrowserStore.shared.modify { st in st.touchAgentUse(paneID: pid) }
        #if os(macOS)
        // The sweep is what flips "is using" → "was using" once the agent
        // goes quiet, so make sure it's ticking even for tabs never parked
        // in the stage.
        AgentStageWindow.shared.startSweepIfNeeded()
        #endif
    }

    public func tabsOpenSplit(url urlStr: String, besideTabId: String?, activate: Bool, windowId: String?) async throws -> String {
        guard let url = URL(string: urlStr) else { throw BrowserJSError.invalidArgs("url") }
        return try await mainAsync { @MainActor in
            let state = BrowserStore.shared.model

            // Resolve the split to join: the tab owning `besideTabId`, else the
            // target window's current tab.
            let destTabID: ID<Tab>
            if let besideTabId {
                guard let tabID = state.paneToTabMapping[ID<WebContent>(raw: besideTabId)] else {
                    throw BrowserJSError.tabNotFound(besideTabId)
                }
                destTabID = tabID
            } else {
                let win: ID<WindowState>
                if let resolved = self.resolveWindowID(windowId, state: state) {
                    win = resolved
                } else if let preferred = self.preferredCurrentWindow(state: state) {
                    win = preferred
                } else {
                    throw BrowserJSError.windowNotFound(windowId ?? "current")
                }
                guard let current = state.windows[win]?.currentTab else {
                    throw BrowserJSError.invalidArgs("window has no current tab to split; pass besideTabId")
                }
                destTabID = current
            }
            guard state.tabs[destTabID] != nil else { throw BrowserJSError.tabNotFound(destTabID.raw) }

            var paneID: ID<WebContent>!
            BrowserStore.shared.modify { st in
                let pid = ID<WebContent>.assign()
                paneID = pid
                let pane = Pane(id: pid, info: .init(url: url))
                st.modifyTab(id: destTabID) { tab in
                    tab.panes.append(pane)
                    if activate {
                        tab.focusedPaneIdx = tab.panes.count - 1
                    }
                }
            }
            return paneID.raw
        }
    }

    public func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String {
        // Load via about:blank then write HTML once the webview is live.
        let id = try await tabsOpen(url: "about:blank", background: false, windowId: windowId)
        try await main {
            let wc = try Self.liveWebContent(forTabID: id)
            wc.load(html: html, baseURL: nil)
            // Title: best-effort — we set it on the next info update via JS.
            if let title {
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                try wc.wkWebviewOrThrow.evaluateJavaScript("document.title = \"\(escaped)\"")
            }
            return ()
        }
        return id
    }

    public func tabsClose(id: String) async throws {
        try await main {
            let pid = ID<WebContent>(raw: id)
            guard BrowserStore.shared.model.paneToTabMapping[pid] != nil else { throw BrowserJSError.tabNotFound(id) }
            BrowserStore.shared.close(webContentId: pid, removeIfPinned: false)
        }
    }

    public func tabsActivate(id: String) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: id)
            guard let tabID = state.paneToTabMapping[pid],
                  let tab = state.tabs[tabID],
                  let loc = state.windowAndSpace(containingTabId: tabID)
            else { throw BrowserJSError.tabNotFound(id) }
            // Activating a pane inside a split must also focus that pane —
            // otherwise the tab comes forward still showing a sibling.
            let paneIdx = tab.panes.asArray.firstIndex { $0.id == pid }
            BrowserStore.shared.modify { st in
                // Bring the tab's space forward too, if the window shows another.
                st.performInSpace(loc.space, window: loc.window, keepSwitched: true) { st in
                    st.activate(tabId: tabID, in: loc.window)
                    st.unghostTab(id: tabID)
                    if let paneIdx {
                        st.modifyTab(id: tabID) { $0.focusedPaneIdx = paneIdx }
                    }
                }
            }
        }
    }

    public func tabsMove(id: String, toIndex: Int) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: id)
            // Folders have no panes, so accept their tab id directly.
            let asTab = ID<Tab>(raw: id)
            guard let tabID = state.paneToTabMapping[pid] ?? (state.tabs[asTab]?.isFolder == true ? asTab : nil),
                  let loc = state.windowAndSpace(containingTabId: tabID)
            else { throw BrowserJSError.tabNotFound(id) }
            BrowserStore.shared.modify { st in
                guard var tabs = st.windows[loc.window]?.perProfileData[loc.space]?.tabs,
                      let oldIdx = tabs.firstIndex(of: tabID)
                else { return }
                tabs.remove(at: oldIdx)
                let clamped = max(0, min(tabs.count, toIndex))
                tabs.insert(tabID, at: clamped)
                st.windows[loc.window]?.perProfileData[loc.space]?.tabs = tabs
            }
        }
    }

    public func tabsGet(id: String) async throws -> BrowserJSTabInfo {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: id)
            guard let tabID = state.paneToTabMapping[pid],
                  let tab = state.tabs[tabID],
                  let pane = tab.panes[pid]
            else { throw BrowserJSError.tabNotFound(id) }
            let loc = state.windowAndSpace(containingTabId: tabID)
            let idx = loc.flatMap { state.windows[$0.window]?.perProfileData[$0.space]?.tabs.firstIndex(of: tabID) }
            return self.tabInfo(forPane: pane, tab: tab, windowID: loc?.window, indexInWindow: idx, spaceID: loc?.space, state: state)
        }
    }

    public func tabsNavigate(id: String, url urlStr: String) async throws {
        guard let url = URL(string: urlStr) else { throw BrowserJSError.invalidArgs("url") }
        try await main {
            let wc = try Self.liveWebContent(forTabID: id)
            wc.load(url: url)
        }
    }

    // MARK: - Content

    public func contentRead(id: String, as kind: String) async throws -> String {
        try await mainAsync { @MainActor in
            let wc = try await Self.loadedWebContent(forTabID: id)
            switch kind {
            case "html":
                let html = try await wc.wkWebviewOrThrow.evaluateAsyncJS("return document.documentElement.outerHTML;")
                return html as? String ?? ""
            case "markdown":
                let html = try await wc.wkWebviewOrThrow.evaluateAsyncJS("return document.documentElement.outerHTML;") as? String ?? ""
                return BrowserJSLiveHost.htmlToMarkdown(html)
            default: // "text"
                let text = (try await wc.wkWebviewOrThrow.evaluateAsyncJS("return document.documentElement.innerText;")) as? String ?? ""
                if !text.isEmpty { return text }
                // `innerText` is empty for tabs that have never been rendered
                // (e.g. opened with `{background:true}`) because layout hasn't
                // run. Fall back to the DOM's text, which is available without
                // rendering — same source the `html`/`markdown` reads use.
                let html = (try await wc.wkWebviewOrThrow.evaluateAsyncJS("return document.documentElement.outerHTML;")) as? String ?? ""
                return BrowserJSLiveHost.htmlToMarkdown(html)
            }
        }
    }

    public func contentScreenshot(id: String) async throws -> BrowserJSImage {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            let wc = try await Self.loadedWebContent(forTabID: id)
            #if os(macOS)
            let webview = try wc.wkWebviewOrThrow
            self.touchAgentUse(pid)
            // A webview that isn't in any window has no viewport and snapshots
            // to a zero-sized image. Background / ghost tabs are parked in the
            // offscreen stage window so they render without being shown.
            let wasDetached = webview.window == nil
            AgentStageWindow.shared.ensureRenderable(webview)
            if wasDetached {
                // Give WebKit a moment to lay out at the new size and paint.
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let cfg = WKSnapshotConfiguration()
            cfg.afterScreenUpdates = true
            // Render at 1× (CSS pixels) rather than the Retina backing scale, so
            // pixel coordinates read off the image are exactly the coordinates
            // `page.click` expects — and the image is a quarter the size.
            let img: NSImage = try await webview.takeSnapshot(configuration: cfg)
            guard img.size.width > 0, img.size.height > 0,
                  let png = Self.png1x(from: img),
                  !png.isEmpty
            else { throw BrowserJSError.underlying("screenshot unavailable — tab has no rendered content yet (is it still loading?)") }
            return BrowserJSImage(mime: "image/png", data: png.base64EncodedString())
            #else
            throw BrowserJSError.notImplemented("contentScreenshot (macOS only)")
            #endif
        }
    }

    #if os(macOS)
    /// Re-render `img` (whose bitmap is at the display's backing scale, 2× on
    /// Retina) into a bitmap with one pixel per point, then PNG-encode it.
    private static func png1x(from img: NSImage) -> Data? {
        let w = Int(img.size.width.rounded()), h = Int(img.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .copy, fraction: 1)
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    // MARK: - Page eval

    public func pageEval(id: String, js: String) async throws -> Any? {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            let wc = try await Self.loadedWebContent(forTabID: id)
            let webview = try wc.wkWebviewOrThrow
            self.touchAgentUse(pid)
            #if os(macOS)
            AgentStageWindow.shared.ensureRenderable(webview)
            #endif
            return try await webview.evalReturningValue(js)
        }
    }

    public func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            // Evaluate the predicate directly so `evalReturningValue` captures a
            // bare-expression predicate's value (e.g. `document.readyState ===
            // 'complete'`). Wrapping it in a return-less IIFE, as before, always
            // yielded undefined → null and the wait never resolved.
            let v: Any?
            do {
                v = try await pageEval(id: id, js: predicateJs)
            } catch let error as BrowserJSError {
                if case .tabNotFound = error { throw error }
                v = nil
            } catch {
                v = nil
            }
            if let v, !(v is NSNull) {
                if let b = v as? Bool, b { return v }
                if (v as? Bool) == nil { return v }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw BrowserJSError.underlying("page.waitFor timed out after \(timeoutMs)ms; predicate never became truthy: \(predicateJs)")
    }

    // MARK: - Computer use

    public func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try await self.webview(forID: id)
            await BrowserJSInputDispatcher.click(in: webview, x: CGFloat(x), y: CGFloat(y), button: button, clickCount: max(1, clickCount))
        }
        #else
        throw BrowserJSError.notImplemented("pageClick (macOS only)")
        #endif
    }

    public func pageType(id: String, text: String) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try await self.webview(forID: id)
            await BrowserJSInputDispatcher.type(in: webview, text: text)
        }
        #else
        throw BrowserJSError.notImplemented("pageType (macOS only)")
        #endif
    }

    public func pageKey(id: String, key: String, modifiers: [String]) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try await self.webview(forID: id)
            await BrowserJSInputDispatcher.key(in: webview, key: key, modifiers: modifiers)
        }
        #else
        throw BrowserJSError.notImplemented("pageKey (macOS only)")
        #endif
    }

    public func pageScroll(id: String, dx: Double, dy: Double) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try await self.webview(forID: id)
            BrowserJSInputDispatcher.scroll(in: webview, dx: CGFloat(dx), dy: CGFloat(dy))
        }
        #else
        throw BrowserJSError.notImplemented("pageScroll (macOS only)")
        #endif
    }

    /// Like `liveWebContent`, but if the WebContent had to be created, waits
    /// for its first navigation to commit — otherwise the caller would act on
    /// the brand-new webview's initial about:blank document.
    @MainActor
    static func loadedWebContent(forTabID id: String) async throws -> WebContent {
        let wasLive = BrowserStore.shared.liveWebContent(forId: ID<WebContent>(raw: id)) != nil
        let wc = try liveWebContent(forTabID: id)
        if !wasLive { try await waitForInitialCommit(wc) }
        return wc
    }

    /// Waits (briefly) for a fresh webview's real navigation to commit.
    /// (`webview.url` is set as soon as the load is *provisional*, so it can't
    /// be the signal; the back/forward list only gets its current item once
    /// the navigation commits.)
    @MainActor
    static func waitForInitialCommit(_ wc: WebContent) async throws {
        guard let webview = wc.wkWebview else { return }
        let deadline = Date().addingTimeInterval(8)
        while webview.backForwardList.currentItem == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The live WebContent for a BrowserJS tab id, creating it if needed.
    /// Resolves across every space (not just the ones windows are displaying),
    /// so agents can drive tabs the user isn't looking at.
    @MainActor
    static func liveWebContent(forTabID id: String) throws -> WebContent {
        let pid = ID<WebContent>(raw: id)
        guard let loc = BrowserStore.shared.model.windowAndSpace(containingWebContentId: pid),
              let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: loc.window)
        else { throw BrowserJSError.tabNotFound(id) }
        return wc
    }

    @MainActor
    private func webview(forID id: String) async throws -> WKWebView {
        let pid = ID<WebContent>(raw: id)
        let wc = try await Self.loadedWebContent(forTabID: id)
        let webview = try wc.wkWebviewOrThrow
        touchAgentUse(pid)
        #if os(macOS)
        AgentStageWindow.shared.ensureRenderable(webview)
        #endif
        return webview
    }

    // MARK: - Windows

    public func windowsList() async throws -> [BrowserJSWindowInfo] {
        try await main {
            let state = BrowserStore.shared.model
            return state.windows.map { (id, win) in self.windowInfo(win, id: id, state: state) }
        }
    }

    public func windowsGetCurrent() async throws -> BrowserJSWindowInfo? {
        try await main {
            let state = BrowserStore.shared.model
            guard let winID = self.preferredCurrentWindow(state: state),
                  let win = state.windows[winID] else { return nil }
            return self.windowInfo(win, id: winID, state: state)
        }
    }

    public func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? {
        try await main {
            let state = BrowserStore.shared.model
            let winID = ID<WindowState>(raw: id)
            guard let win = state.windows[winID] else { return nil }
            return self.windowInfo(win, id: winID, state: state)
        }
    }

    // MARK: - Splits

    public func splitsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSSplitInfo] {
        try await main {
            let state = BrowserStore.shared.model
            let targetWindow = self.resolveWindowID(windowId, state: state)
            let space = try spaceId.map { try self.resolveSpaceID($0, state: state) }
            var out: [BrowserJSSplitInfo] = []
            for (winID, win) in state.windows {
                if let targetWindow, winID != targetWindow { continue }
                let space = space ?? win.profile
                for (idx, tabID) in self.tabIDs(inWindow: win, space: space).enumerated() {
                    guard let tab = state.tabs[tabID] else { continue }
                    out.append(self.splitInfo(forTab: tab, windowID: winID, spaceID: space, indexInWindow: idx))
                }
            }
            return out
        }
    }

    public func splitsGet(tabId: String) async throws -> BrowserJSSplitInfo {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: tabId)
            guard let tabID = state.paneToTabMapping[pid], let tab = state.tabs[tabID] else {
                throw BrowserJSError.tabNotFound(tabId)
            }
            let loc = state.windowAndSpace(containingTabId: tabID)
            let idx = loc.flatMap { state.windows[$0.window]?.perProfileData[$0.space]?.tabs.firstIndex(of: tabID) }
            return self.splitInfo(forTab: tab, windowID: loc?.window, spaceID: loc?.space, indexInWindow: idx)
        }
    }

    public func splitsSeparate(tabId: String) async throws -> [String] {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: tabId)
            guard let tabID = state.paneToTabMapping[pid], let tab = state.tabs[tabID] else {
                throw BrowserJSError.tabNotFound(tabId)
            }
            // Pane ids survive the separation — capture them before mutating.
            let paneIDs = tab.panes.map { $0.id.raw }
            guard tab.isSplit else { return paneIDs }
            BrowserStore.shared.modify { st in
                st.separateSplitTabs(tabId: tabID)
            }
            return paneIDs
        }
    }

    // MARK: - Spaces (profiles)

    public func spacesList(windowId: String?, includeHidden: Bool) async throws -> [BrowserJSSpaceInfo] {
        try await main {
            let state = BrowserStore.shared.model
            let win = self.resolveWindowID(windowId, state: state) ?? self.preferredCurrentWindow(state: state)
            return state.profiles.values
                .filter { includeHidden || !$0.isHidden }
                .sorted { $0.creationOrder < $1.creationOrder }
                .map { self.spaceInfo($0, resolvedWindow: win, state: state) }
        }
    }

    public func spacesGetCurrent(windowId: String?) async throws -> BrowserJSSpaceInfo? {
        try await main {
            let state = BrowserStore.shared.model
            guard let winID = self.resolveWindowID(windowId, state: state) ?? self.preferredCurrentWindow(state: state),
                  let profile = state.windows[winID].flatMap({ state.profiles[$0.profile] })
            else { return nil }
            return self.spaceInfo(profile, resolvedWindow: winID, state: state)
        }
    }

    public func spacesActivate(spaceId: String, windowId: String?) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let space = try self.resolveSpaceID(spaceId, state: state)
            guard let winID = self.resolveWindowID(windowId, state: state) ?? self.preferredCurrentWindow(state: state) else {
                throw BrowserJSError.windowNotFound(windowId ?? "current")
            }
            // A hidden space is absent from the carousel; switching a window to
            // it would strand the user with no way back to it.
            if state.profiles[space]?.isHidden == true {
                throw BrowserJSError.invalidArgs("space \(spaceId) is hidden; unhide it in Settings first")
            }
            BrowserStore.shared.modify { st in
                st.windows[winID]?.profile = space
            }
        }
    }

    public func spacesSetChatMode(spaceId: String, enabled: Bool) async throws {
        try await main {
            BrowserStore.shared.setChatMode(enabled)
        }
    }

    // MARK: - Folders

    public func foldersList(spaceId: String?, windowId: String?) async throws -> [BrowserJSFolderInfo] {
        try await main {
            let state = BrowserStore.shared.model
            let space = try self.resolveSpaceOrCurrent(spaceId, windowId: windowId, state: state)
            return state.folderTabIDs(inSpace: space).compactMap { self.folderInfo(folderTabID: $0, state: state) }
        }
    }

    public func foldersGet(folderId: String) async throws -> BrowserJSFolderInfo {
        try await main {
            let state = BrowserStore.shared.model
            guard let info = self.folderInfo(folderTabID: ID<Tab>(raw: folderId), state: state) else {
                throw BrowserJSError.folderNotFound(folderId)
            }
            return info
        }
    }

    public func foldersCreate(name: String, spaceId: String?, windowId: String?) async throws -> String {
        try await main {
            let state = BrowserStore.shared.model
            let space = try self.resolveSpaceOrCurrent(spaceId, windowId: windowId, state: state)
            guard let winID = self.resolveWindowID(windowId, state: state) ?? self.preferredCurrentWindow(state: state) else {
                throw BrowserJSError.windowNotFound(windowId ?? "current")
            }
            var id: ID<Tab>?
            BrowserStore.shared.modify { st in
                id = st.createFolder(name: name, windowID: winID, profileId: space)
            }
            guard let id else { throw BrowserJSError.windowNotFound(winID.raw) }
            return id.raw
        }
    }

    public func foldersRename(folderId: String, name: String) async throws {
        try await main {
            let id = ID<Tab>(raw: folderId)
            guard BrowserStore.shared.model.folder(id: id) != nil else { throw BrowserJSError.folderNotFound(folderId) }
            BrowserStore.shared.modify { $0.renameFolder(id: id, name: name) }
        }
    }

    public func foldersDelete(folderId: String, closeTabs: Bool, windowId: String?) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let id = ID<Tab>(raw: folderId)
            guard state.folder(id: id) != nil else { throw BrowserJSError.folderNotFound(folderId) }
            let win = closeTabs ? nil : (self.resolveWindowID(windowId, state: state) ?? self.preferredCurrentWindow(state: state))
            BrowserStore.shared.modify { $0.deleteFolder(id: id, moveTabsToWindow: win) }
        }
    }

    public func foldersAddTab(tabId: String, folderId: String, open: Bool) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let folderID = ID<Tab>(raw: folderId)
            guard state.folder(id: folderID) != nil else { throw BrowserJSError.folderNotFound(folderId) }
            guard let tabID = state.paneToTabMapping[ID<WebContent>(raw: tabId)] else { throw BrowserJSError.tabNotFound(tabId) }
            BrowserStore.shared.modify { $0.addTab(tabID, toFolder: folderID, open: open) }
        }
    }

    public func foldersRemoveTab(tabId: String) async throws {
        try await main {
            let state = BrowserStore.shared.model
            guard let tabID = state.paneToTabMapping[ID<WebContent>(raw: tabId)] else { throw BrowserJSError.tabNotFound(tabId) }
            guard state.folderTab(containingTabId: tabID) != nil else { throw BrowserJSError.invalidArgs("tab \(tabId) is not in a folder") }
            BrowserStore.shared.modify { $0.removeTabFromFolder(tabID) }
        }
    }

    // MARK: - Network capture (Section 7)

    public func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary] {
        let entries = await NetworkCaptureStore.shared.entries(filter: filter)
        return entries.map { Self.summary(from: $0) }
    }

    public func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary] {
        let entries = await NetworkCaptureStore.shared.grep(pattern: pattern, where: field)
        return entries.map { Self.summary(from: $0) }
    }

    public func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse {
        #if os(macOS)
        return try await NetworkSyntheticFetch.fetch(req, captureStore: NetworkCaptureStore.shared)
        #else
        throw BrowserJSError.notImplemented("net.fetch (macOS only)")
        #endif
    }

    public func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse {
        guard let entry = await NetworkCaptureStore.shared.entry(id: entryId) else {
            throw BrowserJSError.invalidArgs("entryId not found")
        }
        let req = NetFetchRequest(
            url: overrides?.url ?? entry.url,
            method: overrides?.method ?? entry.method,
            headers: overrides?.headers ?? entry.requestHeaders,
            body: overrides?.body ?? entry.requestBody,
            cookiesFrom: overrides?.cookiesFrom
        )
        return try await netFetch(req: req)
    }

    public func netCaptureOrigin(origin: String, enabled: Bool) async throws {
        await NetworkCaptureStore.shared.setCaptureEnabled(origin: origin, enabled: enabled)
    }

    // MARK: - Webapps

    public func webappCreate(name: String, files: [String: String], exposeBrowserJS: Bool) async throws -> String {
        // exposeBrowserJS: v1 always exposes `window.browser` to tang:// pages
        // (the scheme is the gate). The flag is kept in the API for a future
        // per-app opt-out.
        _ = exposeBrowserJS
        let slug = try TangAppStore.shared.create(name: name, files: files)
        TangAppRegistry.shared.reload()
        return try await tabsOpen(url: "tang://\(slug)/", background: false, windowId: nil)
    }

    // MARK: - Scheduled tasks

    public func tasksList() async throws -> BrowserJSTasksInfo {
        await MainActor.run { ScheduledTasksStore.shared.reloadFromDisk() }
        let tasks = ScheduledTasksStore.shared.model.tasks
        return BrowserJSTasksInfo(
            filePath: ScheduledTasksStore.fileURL.path,
            dataDirectory: ScheduledTasksStore.dataDirectoryURL.path,
            tasks: tasks.map { t in
                BrowserJSTasksInfo.Task(
                    id: t.id, title: t.title, enabled: t.isEnabled,
                    schedule: t.scheduleDescription,
                    nextRunAt: t.nextFireDate().map(\.timeIntervalSince1970),
                    lastRunAt: t.lastRunAt.map(\.timeIntervalSince1970),
                    lastRunSummary: t.lastRunSummary, lastRunWasError: t.lastRunWasError ?? false,
                    dataFilePath: ScheduledTasksStore.dataFileURL(taskID: t.id).path
                )
            }
        )
    }

    // MARK: - Notes

    public func notesWrite(agentKey: String?, title: String, markdown: String?, html: String?, show: String) async throws -> BrowserJSNoteInfo {
        guard markdown != nil || html != nil else { throw BrowserJSError.invalidArgs("markdown or html") }
        let url = try TangAppStore.shared.writeNote(title: title, markdown: markdown, html: html)
        if show == "none" { return BrowserJSNoteInfo(url: url.absoluteString, tabId: nil) }
        let tabId = try await chatPresent(agentKey: agentKey, tabId: nil, url: url.absoluteString, show: show, note: nil)
        return BrowserJSNoteInfo(url: url.absoluteString, tabId: tabId)
    }

    // MARK: - Agents
    // Backed by BrowserAgentManager, which is platform-neutral over the
    // `Agent`/`AgentProvider` protocols. On platforms with no registered
    // provider only `create` fails.

    public func agentCreate(options: BrowserJSAgentCreateOptions) async throws -> String {
        try await BrowserAgentManager.shared.create(options: options)
    }

    public func agentSend(id: String, text: String, images: [BrowserJSImage]) async throws {
        try await BrowserAgentManager.shared.send(id: id, text: text, images: images)
    }

    public func agentAwait(id: String, timeoutMs: Int, since: Int?) async throws -> BrowserJSAgentAwaitResult {
        try await BrowserAgentManager.shared.awaitIdle(id: id, timeoutMs: timeoutMs, since: since)
    }

    public func agentRespondTool(callId: String, text: String, isError: Bool) async throws {
        try await BrowserAgentManager.shared.respondTool(callId: callId, text: text, isError: isError)
    }

    public func agentMessages(id: String, since: Int) async throws -> [BrowserJSAgentMessage] {
        try await BrowserAgentManager.shared.messages(id: id, since: since)
    }

    public func agentList() async throws -> [BrowserJSAgentInfo] {
        await BrowserAgentManager.shared.list()
    }

    public func agentInterrupt(id: String) async throws {
        try await BrowserAgentManager.shared.interrupt(id: id)
    }

    public func agentDispose(id: String) async throws {
        try await BrowserAgentManager.shared.dispose(id: id)
    }

    // MARK: - Autofill (identity + saved logins)

    @MainActor
    private func autofillProfile(spaceId: String?) throws -> ID<Profile> {
        guard AutofillSettings.isEnabled else { throw BrowserJSError.underlying("Autofill is turned off in Settings → Autofill") }
        if let spaceId { return try resolveSpaceID(spaceId, state: BrowserStore.shared.model) }
        return AutofillStore.shared.currentProfileID()
    }

    public func credentialsLookup(domain: String, spaceId: String?) async throws -> [BrowserJSCredentialInfo] {
        try await main {
            let profile = try self.autofillProfile(spaceId: spaceId)
            return AutofillStore.shared.data(for: profile).credentials(forHost: domain).map {
                BrowserJSCredentialInfo(id: $0.id.uuidString, username: $0.username, domain: $0.domain, host: $0.host, lastUsed: $0.lastUsed.timeIntervalSince1970)
            }
        }
    }

    public func credentialsHasPassword(domain: String, username: String?, spaceId: String?) async throws -> Bool {
        try await main {
            let profile = try self.autofillProfile(spaceId: spaceId)
            let matches = AutofillStore.shared.data(for: profile).credentials(forHost: domain)
            if let username { return matches.contains { $0.username.lowercased() == username.lowercased() } }
            return !matches.isEmpty
        }
    }

    public func credentialsFillPassword(tabId: String, username: String?, domain: String?) async throws -> BrowserJSFillPasswordResult {
        #if os(macOS)
        return try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: tabId)
            let wc = try await Self.loadedWebContent(forTabID: tabId)
            guard let session = wc.autofill else {
                throw BrowserJSError.notImplemented("credentials.fillPassword is not supported on this tab's engine")
            }
            self.touchAgentUse(pid)
            if let view = wc.wkWebview { AgentStageWindow.shared.ensureRenderable(view) }
            let filledUsername = try await session.fillPasswordForAgent(username: username, domain: domain)
            return BrowserJSFillPasswordResult(filled: true, username: filledUsername)
        }
        #else
        throw BrowserJSError.notImplemented("credentials.fillPassword (macOS only)")
        #endif
    }

    public func profileGet(spaceId: String?) async throws -> BrowserJSProfileInfo {
        try await main {
            let profile = try self.autofillProfile(spaceId: spaceId)
            let data = AutofillStore.shared.data(for: profile)
            let names = data.names.sortedByUse()
            return BrowserJSProfileInfo(
                name: names.first?.full,
                givenName: names.first?.given.nilIfEmpty,
                familyName: names.first?.family.nilIfEmpty,
                names: names.map { $0.full },
                emails: data.emails.sortedByUse().map { $0.value },
                phones: data.phones.sortedByUse().map { $0.value },
                organizations: data.organizations.sortedByUse().map { $0.value },
                addresses: data.addresses.sortedByUse().map {
                    BrowserJSAddressInfo(line1: $0.line1, line2: $0.line2, city: $0.city, state: $0.state, postalCode: $0.postalCode, country: $0.country, oneLine: $0.oneLine)
                },
                savedLoginDomains: Set(data.credentials.map { $0.domain }).sorted()
            )
        }
    }

    private static func summary(from e: NetCaptureEntry) -> NetEntrySummary {
        NetEntrySummary(
            id: e.id,
            ts: e.ts,
            url: e.url,
            method: e.method,
            status: e.status,
            request: NetEntryHalf(headers: e.requestHeaders, body: e.requestBody),
            response: NetEntryHalf(headers: e.responseHeaders, body: e.responseBody)
        )
    }

    // MARK: - Helpers

    private func tabInfo(forPane pane: Pane, tab: Tab, windowID: ID<WindowState>?, indexInWindow: Int?, spaceID: ID<Profile>?, state: BrowserState) -> BrowserJSTabInfo {
        let kind: String = {
            if let url = pane.info.url {
                if url.scheme == TangSchemeHandler.scheme { return "webapp" }
                if let key = NativePageKey(url: url) { return key.kindString }
            }
            return "web"
        }()
        let paneIDs = tab.panes.map { $0.id.raw }
        return BrowserJSTabInfo(
            id: pane.id.raw,
            windowId: windowID?.raw,
            url: pane.info.url?.absoluteString,
            title: pane.info.title,
            index: indexInWindow,
            kind: kind,
            isGhost: pane.isGhost,
            agentActiveUntil: pane.agentActiveUntil?.timeIntervalSince1970,
            splitId: tab.id.raw,
            splitTabIds: paneIDs,
            isFocusedInSplit: tab.focusedPane?.id == pane.id,
            spaceId: spaceID?.raw,
            folderId: state.folderTab(containingTabId: tab.id)?.id.raw
        )
    }

    private func folderInfo(folderTabID: ID<Tab>, state: BrowserState) -> BrowserJSFolderInfo? {
        guard let folder = state.folder(id: folderTabID) else { return nil }
        let loc = state.windowAndSpace(containingTabId: folderTabID)
        let index = loc.flatMap { state.windows[$0.window]?.perProfileData[$0.space]?.tabs.firstIndex(of: folderTabID) }
        return BrowserJSFolderInfo(
            id: folderTabID.raw,
            spaceId: loc?.space.raw,
            windowId: loc?.window.raw,
            index: index,
            name: folder.name,
            tabIds: folder.tabs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
            openTabIds: folder.openTabs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
            splitIds: folder.tabs.filter { state.tabs[$0] != nil }.map { $0.raw }
        )
    }

    /// `spaceId` if given, else the resolved (or current) window's space.
    @MainActor
    private func resolveSpaceOrCurrent(_ spaceId: String?, windowId: String?, state: BrowserState) throws -> ID<Profile> {
        if let spaceId { return try resolveSpaceID(spaceId, state: state) }
        guard let winID = resolveWindowID(windowId, state: state) ?? preferredCurrentWindow(state: state),
              let profile = state.windows[winID]?.profile
        else { throw BrowserJSError.windowNotFound(windowId ?? "current") }
        return profile
    }

    /// A space's tab list is stored per-window (`WindowState.perProfileData`).
    /// For the window's current space this is just `win.tabs`.
    private func tabIDs(inWindow win: WindowState, space: ID<Profile>) -> [ID<Tab>] {
        win.profile == space ? win.tabs : (win.perProfileData[space]?.tabs ?? [])
    }

    @MainActor
    private func windowInfo(_ win: WindowState, id: ID<WindowState>, state: BrowserState) -> BrowserJSWindowInfo {
        BrowserJSWindowInfo(
            id: id.raw,
            tabIds: win.tabs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
            // The visible pane of the current tab — NOT `panes.first`, which is
            // a different pane whenever the current tab is a split.
            currentTabId: win.currentTab.flatMap { state.tabs[$0]?.focusedPane?.id.raw },
            spaceId: win.profile.raw,
            splitIds: win.tabs.filter { state.tabs[$0] != nil }.map { $0.raw }
        )
    }

    private func splitInfo(forTab tab: Tab, windowID: ID<WindowState>?, spaceID: ID<Profile>?, indexInWindow: Int?) -> BrowserJSSplitInfo {
        BrowserJSSplitInfo(
            id: tab.id.raw,
            windowId: windowID?.raw,
            spaceId: spaceID?.raw,
            index: indexInWindow,
            tabIds: tab.panes.map { $0.id.raw },
            focusedTabId: tab.focusedPane?.id.raw,
            title: tab.customTitle ?? tab.focusedPane?.info.title
        )
    }

    private func spaceInfo(_ profile: Profile, resolvedWindow: ID<WindowState>?, state: BrowserState) -> BrowserJSSpaceInfo {
        let tabIDs = resolvedWindow.flatMap { state.windows[$0] }.map { self.tabIDs(inWindow: $0, space: profile.id) } ?? []
        return BrowserJSSpaceInfo(
            id: profile.id.raw,
            title: profile.title,
            autoTitle: profile.autoTitle,
            displayName: profile.title ?? profile.autoTitle ?? "Space \(profile.creationOrder + 1)",
            emoji: profile.emoji,
            index: profile.creationOrder,
            hidden: profile.isHidden,
            chatMode: state.isChatMode,
            isCurrent: resolvedWindow.flatMap { state.windows[$0]?.profile } == profile.id,
            windowIds: state.windows.values.filter { $0.profile == profile.id }.map { $0.id.raw },
            tabIds: tabIDs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
            splitIds: tabIDs.filter { state.tabs[$0] != nil }.map { $0.raw }
        )
    }

    private func resolveWindowID(_ raw: String?, state: BrowserState) -> ID<WindowState>? {
        guard let raw else { return nil }
        let id = ID<WindowState>(raw: raw)
        return state.windows[id] != nil ? id : nil
    }

    private func resolveSpaceID(_ raw: String, state: BrowserState) throws -> ID<Profile> {
        let id = ID<Profile>(raw: raw)
        guard state.profiles[id] != nil else { throw BrowserJSError.spaceNotFound(raw) }
        return id
    }

    @MainActor
    private func preferredCurrentWindow(state: BrowserState) -> ID<WindowState>? {
        // A call from a terminal / agent tab in the browser acts in that tab's window.
        if let ctx = state.callOriginContext() {
            return ctx.windowID
        }
        // Most-recently-active window by lastActive
        let sorted = state.windows.values.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        return sorted.first?.id
    }

    @MainActor
    private func ensureWindow() -> ID<WindowState> {
        var id: ID<WindowState>!
        BrowserStore.shared.modify { st in
            id = st.getOrCreateActiveWindow().id
        }
        return id
    }

    private func main<T: Sendable>(_ block: @MainActor @Sendable @escaping () throws -> T) async throws -> T {
        try await MainActor.run { try block() }
    }

    private func mainAsync<T: Sendable>(_ block: @MainActor @Sendable @escaping () async throws -> T) async throws -> T {
        try await Task { @MainActor in try await block() }.value
    }

    static func htmlToMarkdown(_ html: String) -> String {
        // Very simple HTML → Markdown via stripping tags. Reeeed/Ink is the
        // proper path (Q30) and lives in the existing Reader pipeline; we
        // can wire the richer path in a follow-up. For now: text only.
        //
        // First drop the *contents* of non-text elements — otherwise raw JS/CSS
        // source leaks into the output (e.g. inline <script> bootstraps, <style>
        // rules). Tag-stripping alone only removes the tags, not their bodies.
        var html = html
        for tag in ["script", "style", "noscript", "template"] {
            let block = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
            html = html.replacingOccurrences(of: block, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let pattern = "<[^>]+>"
        let stripped = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

extension WKWebView {
    func evaluateAsyncJS(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            DispatchQueue.main.async {
                self.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let v): cont.resume(returning: v)
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
        }
    }

    /// REPL-style eval for `page.eval`: returns the value of the snippet's final
    /// expression so a bare `document.title`, `1+2`, or an IIFE yields a value
    /// without an explicit `return`.
    ///
    /// `callAsyncJavaScript` treats the snippet as an async-function *body*, so a
    /// bare expression returns nothing (→ null). We first try the snippet as a
    /// single expression — `return (<snippet>);` — which covers everything from
    /// `innerWidth` to `(function(){ ... })()` and `JSON.stringify({...})`. If
    /// that is a *syntax* error (the snippet is really a statement list: `const
    /// x = ...; return x`), it runs verbatim and needs its own `return`.
    /// Runtime errors from the expression form are NOT retried — they're real.
    func evalReturningValue(_ js: String) async throws -> Any? {
        var expr = js.trimmingCharacters(in: .whitespacesAndNewlines)
        while expr.hasSuffix(";") {
            expr.removeLast()
            expr = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if expr.isEmpty { return nil }
        do {
            return try await evaluateAsyncJS("return (\n\(expr)\n);")
        } catch let err as NSError where Self.isSyntaxError(err) {
            return try await evaluateAsyncJS(js)
        }
    }

    private static func isSyntaxError(_ err: NSError) -> Bool {
        if err.domain == WKError.errorDomain, err.code == WKError.javaScriptExceptionOccurred.rawValue {
            let msg = (err.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ""
            return msg.contains("SyntaxError")
        }
        return err.localizedDescription.contains("SyntaxError")
    }
}

private extension WebContent {
    /// BrowserJS agent APIs drive pages through WebKit. Chromium (CEF) tabs
    /// don't support them yet, so surface a typed error instead of crashing.
    var wkWebviewOrThrow: WebContentWebView {
        get throws {
            guard let wkWebview else {
                throw BrowserJSError.notImplemented("This action isn't supported on Chromium-engine tabs yet")
            }
            return wkWebview
        }
    }
}

// MARK: - Inject

extension BrowserJSLiveHost {
    /// Accepts a bare hostname or a full URL; keys are `hostWithoutWWW`.
    private static func injectionHost(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: s.contains("://") ? s : "https://" + s)
        guard let host = url?.hostWithoutWWW.nilIfEmpty else { throw BrowserJSError.invalidArgs("host") }
        return host
    }

    public func injectGet(host: String) async throws -> BrowserJSInjection {
        let h = try Self.injectionHost(host)
        return try await main {
            let state = CleanModeStore.shared.model
            let cfg = state.hostSettings[h] ?? CleanModeState.defaultHostSettings[h]
            return BrowserJSInjection(host: h, css: cfg?.injectCSS?.nilIfEmpty, js: cfg?.injectJS?.nilIfEmpty)
        }
    }

    public func injectSet(host: String, css: String?, js: String?) async throws -> BrowserJSInjection {
        let h = try Self.injectionHost(host)
        guard css != nil || js != nil else { throw BrowserJSError.invalidArgs("css or js") }
        try await main { CleanModeStore.shared.model.setInjection(host: h, css: css, js: js) }
        return try await injectGet(host: h)
    }

    public func injectClear(host: String) async throws {
        let h = try Self.injectionHost(host)
        try await main { CleanModeStore.shared.model.setInjection(host: h, css: "", js: "") }
    }
}

// MARK: - Toolbar buttons

extension BrowserJSLiveHost {
    public func toolbarListButtons() async throws -> [CustomToolbarButton] {
        try await main { BrowserStore.shared.model.toolbarConfig.customButtons }
    }

    public func toolbarGetButton(id: String) async throws -> CustomToolbarButton? {
        try await main { BrowserStore.shared.model.toolbarConfig.customButton(id: id) }
    }

    public func toolbarCreateButton(label: String, icon: String?, bjs: String?, instructions: String?) async throws -> CustomToolbarButton {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserJSError.invalidArgs("label") }
        let button = CustomToolbarButton(label: trimmed, icon: icon ?? CustomToolbarButton.randomIcon(), bjs: bjs, instructions: instructions)
        try await main { BrowserStore.shared.modify { $0.addCustomToolbarButton(button) } }
        return button
    }

    public func toolbarUpdateButton(id: String, label: String?, icon: String?, bjs: String?, clearBJS: Bool, instructions: String?) async throws -> CustomToolbarButton {
        let updated: CustomToolbarButton? = try await main {
            var result: CustomToolbarButton?
            BrowserStore.shared.modify { st in
                st.updateCustomToolbarButton(id: id) { b in
                    if let label, !label.isEmpty { b.label = label }
                    if let icon, !icon.isEmpty { b.icon = icon }
                    if clearBJS { b.bjs = nil } else if let bjs { b.bjs = bjs }
                    if let instructions { b.instructions = instructions }
                    result = b
                }
            }
            return result
        }
        guard let updated else { throw BrowserJSError.underlying("toolbar button not found: \(id)") }
        return updated
    }

    public func toolbarRemoveButton(id: String) async throws {
        try await main { BrowserStore.shared.modify { $0.removeCustomToolbarButton(id: id) } }
    }

    public func toolbarClickButton(id: String, tabId: String?) async throws {
        let paneID = tabId.map { ID<WebContent>(raw: $0) } ?? BrowserJSCallOrigin.paneID
        try await main {
            let state = BrowserStore.shared.model
            guard state.toolbarConfig.customButton(id: id) != nil else { throw BrowserJSError.underlying("toolbar button not found: \(id)") }
            let windowID = paneID.flatMap { state.windowAndSpace(containingWebContentId: $0)?.window } ?? state.windows.values.first?.id
            guard let windowID else { throw BrowserJSError.windowNotFound("none") }
            ToolbarButtonRunner.click(buttonID: id, webContentID: paneID, windowID: windowID)
        }
    }
}

// MARK: - Memory

extension BrowserJSLiveHost {
    public func memoryScopes() async throws -> [BrowserJSMemoryScope] {
        let scopes = await MainActor.run { MemoryStore.scopes(in: BrowserStore.shared.model) }
        var out: [BrowserJSMemoryScope] = []
        for s in scopes {
            var count: Int? = nil
            if s.enabled {
                count = (try? await MemoryStore.shared.perform(scope: s.id) { db in
                    (try db.scalar("SELECT COUNT(*) FROM events") as? Int64).map(Int.init) ?? 0
                })
            }
            out.append(BrowserJSMemoryScope(id: s.id.uuidString, names: s.names, enabled: s.enabled, eventCount: count))
        }
        return out
    }

    public func memorySchema() async throws -> String {
        MemoryDB.schemaDescription
    }

    private func resolvedMemoryScope(_ explicit: String?) async throws -> UUID {
        let origin = BrowserJSCallOrigin.paneID
        let scope = try await MainActor.run { try MemoryStore.shared.resolveScope(explicit: explicit, originPane: origin) }
        guard MemoryStore.shared.isEnabled(scope) else {
            throw BrowserJSError.invalidArgs("memory is not enabled for scope \(scope.uuidString) (Settings › Memory)")
        }
        return scope
    }

    public func memoryQuery(scope: String?, sql: String, params: [Any], limit: Int) async throws -> [[String: Any]] {
        let scope = try await resolvedMemoryScope(scope)
        let bound: [Any?] = params.map { $0 is NSNull ? nil : $0 }
        return try await MemoryStore.shared.performRead(scope: scope, sql: sql, params: bound, limit: max(1, min(limit, 2000)))
    }

    public func memoryOverview(scope: String?) async throws -> BrowserJSMemoryOverview {
        let scope = try await resolvedMemoryScope(scope)
        let text: String = (try? await MemoryStore.shared.perform(scope: scope) { db in
            (try db.scalar("SELECT value FROM meta WHERE key = 'overview'")) as? String ?? ""
        }) ?? ""
        let updated: String? = try? await MemoryStore.shared.perform(scope: scope) { db in
            (try db.scalar("SELECT value FROM meta WHERE key = 'overview_updated_at'")) as? String
        }
        let info = await MainActor.run { MemoryStore.shared.overviewInfo(scope: scope) }
        return BrowserJSMemoryOverview(scope: scope.uuidString, text: text, updatedAt: updated, status: info.status.rawValue, statusDetail: info.statusDetail)
    }

    public func memorySetOverview(scope: String?, text: String) async throws -> BrowserJSMemoryOverview {
        let scope = try await resolvedMemoryScope(scope)
        await MainActor.run { MemoryStore.shared.setOverview(scope: scope, text: text) }
        let info = await MainActor.run { MemoryStore.shared.overviewInfo(scope: scope) }
        return BrowserJSMemoryOverview(scope: scope.uuidString, text: text, updatedAt: info.updatedAt.map { ISO8601DateFormatter().string(from: $0) }, status: info.status.rawValue, statusDetail: info.statusDetail)
    }
}
