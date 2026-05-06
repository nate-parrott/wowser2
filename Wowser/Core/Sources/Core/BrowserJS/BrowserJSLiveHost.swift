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

    public func tabsList(windowId: String?) async throws -> [BrowserJSTabInfo] {
        try await main {
            let state = BrowserStore.shared.model
            let targetWindow = self.resolveWindowID(windowId, state: state)
            var out: [BrowserJSTabInfo] = []
            for (winID, win) in state.windows {
                if let targetWindow, winID != targetWindow { continue }
                for (idx, tabID) in win.tabs.enumerated() {
                    guard let tab = state.tabs[tabID] else { continue }
                    for pane in tab.panes {
                        out.append(self.tabInfo(forPane: pane, tab: tab, windowID: winID, indexInWindow: idx, state: state))
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
                let pid = ID<WebContent>.assign()
                paneID = pid
                var pane = Pane(id: pid, info: .init(url: url))
                pane.isGhost = ghost
                let tab = Tab(id: .assign(), panes: [pane])
                let loc = st.insertionIndex(window: win, spawningTabId: st.windows[win]?.currentTab)
                st.insertTab(tab, location: loc, inWindow: win)
                if !background {
                    st.activate(tabId: tab.id, in: win)
                }
            }
            // Ghost panes need a live WebContent so the page actually loads in
            // the background. Materialize it eagerly.
            if ghost {
                _ = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: win)
            }
            return paneID.raw
        }
    }

    public func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String {
        // Load via about:blank then write HTML once the webview is live.
        let id = try await tabsOpen(url: "about:blank", background: false, windowId: windowId)
        try await main {
            guard let paneID = ID<WebContent>?.some(.init(raw: id)),
                  let winID = BrowserStore.shared.model.windowContaining(webContentId: paneID)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: winID)
            else { throw BrowserJSError.tabNotFound(id) }
            wc.load(html: html, baseURL: nil)
            // Title: best-effort — we set it on the next info update via JS.
            if let title {
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                wc.webview.evaluateJavaScript("document.title = \"\(escaped)\"")
            }
            return ()
        }
        return id
    }

    public func tabsClose(id: String) async throws {
        try await main {
            let pid = ID<WebContent>(raw: id)
            BrowserStore.shared.close(webContentId: pid, removeIfPinned: false)
        }
    }

    public func tabsActivate(id: String) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: id)
            guard let tabID = state.paneToTabMapping[pid],
                  let winID = state.windowContaining(tabId: tabID)?.id
            else { throw BrowserJSError.tabNotFound(id) }
            BrowserStore.shared.modify { st in
                st.activate(tabId: tabID, in: winID)
                st.unghostTab(id: tabID)
            }
        }
    }

    public func tabsMove(id: String, toIndex: Int) async throws {
        try await main {
            let state = BrowserStore.shared.model
            let pid = ID<WebContent>(raw: id)
            guard let tabID = state.paneToTabMapping[pid],
                  let winID = state.windowContaining(tabId: tabID)?.id
            else { throw BrowserJSError.tabNotFound(id) }
            BrowserStore.shared.modify { st in
                guard var tabs = st.windows[winID]?.tabs,
                      let oldIdx = tabs.firstIndex(of: tabID)
                else { return }
                tabs.remove(at: oldIdx)
                let clamped = max(0, min(tabs.count, toIndex))
                tabs.insert(tabID, at: clamped)
                st.windows[winID]?.tabs = tabs
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
            let winID = state.windowContaining(tabId: tabID)?.id
            let idx = winID.flatMap { state.windows[$0]?.tabs.firstIndex(of: tabID) }
            return self.tabInfo(forPane: pane, tab: tab, windowID: winID, indexInWindow: idx, state: state)
        }
    }

    public func tabsNavigate(id: String, url urlStr: String) async throws {
        guard let url = URL(string: urlStr) else { throw BrowserJSError.invalidArgs("url") }
        try await main {
            let pid = ID<WebContent>(raw: id)
            guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
            else { throw BrowserJSError.tabNotFound(id) }
            wc.load(url: url)
        }
    }

    // MARK: - Content

    public func contentRead(id: String, as kind: String) async throws -> String {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
            else { throw BrowserJSError.tabNotFound(id) }
            switch kind {
            case "html":
                let html = try await wc.webview.evaluateAsyncJS("return document.documentElement.outerHTML;")
                return html as? String ?? ""
            case "markdown":
                let html = try await wc.webview.evaluateAsyncJS("return document.documentElement.outerHTML;") as? String ?? ""
                return BrowserJSLiveHost.htmlToMarkdown(html)
            default: // "text"
                let text = try await wc.webview.evaluateAsyncJS("return document.documentElement.innerText;")
                return text as? String ?? ""
            }
        }
    }

    public func contentScreenshot(id: String) async throws -> BrowserJSImage {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
            else { throw BrowserJSError.tabNotFound(id) }
            #if os(macOS)
            let cfg = WKSnapshotConfiguration()
            cfg.afterScreenUpdates = true
            let img: NSImage = try await wc.webview.takeSnapshot(configuration: cfg)
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return BrowserJSImage(mime: "image/png", data: "") }
            return BrowserJSImage(mime: "image/png", data: png.base64EncodedString())
            #else
            return BrowserJSImage(mime: "image/png", data: "")
            #endif
        }
    }

    // MARK: - Page eval

    public func pageEval(id: String, js: String) async throws -> Any? {
        try await mainAsync { @MainActor in
            let pid = ID<WebContent>(raw: id)
            guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
            else { throw BrowserJSError.tabNotFound(id) }
            return try await wc.webview.evaluateAsyncJS(js)
        }
    }

    public func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let v = try? await pageEval(id: id, js: "return (function(){ \(predicateJs) })();")
            if let v, !(v is NSNull) {
                if let b = v as? Bool, b { return v }
                if (v as? Bool) == nil { return v }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw BrowserJSError.timeout
    }

    // MARK: - Computer use

    public func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try self.webview(forID: id)
            BrowserJSInputDispatcher.click(in: webview, x: CGFloat(x), y: CGFloat(y), button: button, clickCount: max(1, clickCount))
        }
        #else
        throw BrowserJSError.notImplemented("pageClick (macOS only)")
        #endif
    }

    public func pageType(id: String, text: String) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try self.webview(forID: id)
            BrowserJSInputDispatcher.type(in: webview, text: text)
        }
        #else
        throw BrowserJSError.notImplemented("pageType (macOS only)")
        #endif
    }

    public func pageKey(id: String, key: String, modifiers: [String]) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try self.webview(forID: id)
            BrowserJSInputDispatcher.key(in: webview, key: key, modifiers: modifiers)
        }
        #else
        throw BrowserJSError.notImplemented("pageKey (macOS only)")
        #endif
    }

    public func pageScroll(id: String, dx: Double, dy: Double) async throws {
        #if os(macOS)
        try await mainAsync { @MainActor in
            let webview = try self.webview(forID: id)
            BrowserJSInputDispatcher.scroll(in: webview, dx: CGFloat(dx), dy: CGFloat(dy))
        }
        #else
        throw BrowserJSError.notImplemented("pageScroll (macOS only)")
        #endif
    }

    @MainActor
    private func webview(forID id: String) throws -> WKWebView {
        let pid = ID<WebContent>(raw: id)
        guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
              let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
        else { throw BrowserJSError.tabNotFound(id) }
        return wc.webview
    }

    // MARK: - Windows

    public func windowsList() async throws -> [BrowserJSWindowInfo] {
        try await main {
            let state = BrowserStore.shared.model
            return state.windows.map { (id, win) in
                BrowserJSWindowInfo(
                    id: id.raw,
                    tabIds: win.tabs.flatMap { tabID in
                        state.tabs[tabID]?.panes.map { $0.id.raw } ?? []
                    },
                    currentTabId: win.currentTab.flatMap { tid in
                        state.tabs[tid]?.panes[state.tabs[tid]?.focusedPaneIdx ?? 0]?.id.raw
                    }
                )
            }
        }
    }

    public func windowsGetCurrent() async throws -> BrowserJSWindowInfo? {
        try await main {
            let state = BrowserStore.shared.model
            guard let winID = self.preferredCurrentWindow(state: state),
                  let win = state.windows[winID] else { return nil }
            return BrowserJSWindowInfo(
                id: winID.raw,
                tabIds: win.tabs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
                currentTabId: win.currentTab.flatMap { state.tabs[$0]?.panes.first?.id.raw }
            )
        }
    }

    public func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? {
        try await main {
            let state = BrowserStore.shared.model
            let winID = ID<WindowState>(raw: id)
            guard let win = state.windows[winID] else { return nil }
            return BrowserJSWindowInfo(
                id: winID.raw,
                tabIds: win.tabs.flatMap { state.tabs[$0]?.panes.map { $0.id.raw } ?? [] },
                currentTabId: win.currentTab.flatMap { state.tabs[$0]?.panes.first?.id.raw }
            )
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

    private func tabInfo(forPane pane: Pane, tab: Tab, windowID: ID<WindowState>?, indexInWindow: Int?, state: BrowserState) -> BrowserJSTabInfo {
        let kind: String = {
            if let url = pane.info.url, let key = NativePageKey(url: url) {
                switch key {
                case .terminal: return "terminal"
                case .vscode: return "vscode"
                case .fileBrowser: return "files"
                }
            }
            return "web"
        }()
        return BrowserJSTabInfo(
            id: pane.id.raw,
            windowId: windowID?.raw,
            url: pane.info.url?.absoluteString,
            title: pane.info.title,
            index: indexInWindow,
            kind: kind,
            isGhost: pane.isGhost
        )
    }

    private func resolveWindowID(_ raw: String?, state: BrowserState) -> ID<WindowState>? {
        guard let raw else { return nil }
        let id = ID<WindowState>(raw: raw)
        return state.windows[id] != nil ? id : nil
    }

    @MainActor
    private func preferredCurrentWindow(state: BrowserState) -> ID<WindowState>? {
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
}
