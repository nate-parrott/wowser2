import Foundation
import WebKit
import Vision
#if os(macOS)
import AppKit
#endif

// Hooks called from the rest of the app (all main thread), plus the 5-second
// capture tick that records what's on screen.

extension MemoryStore {

    // MARK: - Hooks

    /// From `BrowserStore.webContent(_:infoDidChange:previous:)` — the same
    /// path the omnibox's history logging uses.
    func noteInfoChange(webContent: WebContent, info: WebContent.Info, previous: WebContent.Info?) {
        guard isActive else { return }
        let scope = webContent.datastoreUUID
        guard isEnabled(scope), let url = info.url else { return }
        let paneID = webContent.id
        if url.historyKey != previous?.url?.historyKey {
            // A blank page with no native role isn't a visit.
            if url.absoluteString == "about:blank" { return }
            let tabID = BrowserStore.shared.model.paneToTabMapping[paneID]
            let parent = spawnParents.removeValue(forKey: paneID)
            var event = MemoryEvent(kind: "visit", pageType: Self.pageType(for: url), paneID: paneID.raw, tabID: tabID?.raw,
                                    url: url, title: info.title?.nilIfEmpty, description: info.pageDescription?.nilIfEmpty)
            if let parent {
                event.parentPaneID = parent.paneID.raw
                event.parentURL = parent.url
                event.parentTitle = parent.title
            }
            if let space = Self.space(forPane: paneID, in: BrowserStore.shared.model) {
                event.spaceID = space.id; event.spaceName = space.name
            }
            record(scope: scope, event)
            resetBaseline(key: "screen:" + paneID.raw)
        } else if info.title != previous?.title || info.pageDescription != previous?.pageDescription {
            updateVisitMeta(scope: scope, paneID: paneID.raw, url: url, title: info.title, description: info.pageDescription)
        }
    }

    /// From `BrowserStore.webContent(_:didSpawnNewWebContent:shouldActivate:)`.
    func noteSpawn(parent: WebContent, child: WebContent) {
        guard isActive else { return }
        spawnParents[child.id] = (parent.id, parent.info.url, parent.info.title)
        if spawnParents.count > 64 { spawnParents.removeAll() }
    }

    /// From `WebContentWebKit.webView(_:didFinish:)`: capture the screen
    /// shortly after load, ahead of the regular 5s cadence.
    func notePageLoaded(webContent: WebContent) {
        guard isActive, isEnabled(webContent.datastoreUUID) else { return }
        let id = webContent.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isActive, let wc = BrowserStore.shared.existingWebContent(forId: id) else { return }
            let state = BrowserStore.shared.model
            guard let pane = state.pane(forId: id), let tabID = state.paneToTabMapping[id] else { return }
            self.captureWebPane(wc, pane: pane, tabID: tabID)
        }
    }

    /// From `DownloadManager.downloadDidFinish`.
    func noteDownload(scope: UUID?, download: Download, sourceURL: URL?, sourceTitle: String?, paneID: ID<WebContent>?) {
        guard isActive, let scope, isEnabled(scope) else { return }
        let size = download.currentSize > 0 ? download.currentSize : download.estimatedSize
        var event = MemoryEvent(
            kind: "download", pageType: "files", paneID: paneID?.raw,
            url: download.url, title: download.suggestedFilename, text: download.destinationURL.path,
            parentURL: sourceURL, parentTitle: sourceTitle,
            extra: ["filename": download.suggestedFilename, "path": download.destinationURL.path, "size": size,
                    "sourceUrl": sourceURL?.absoluteString ?? NSNull()]
        )
        if let paneID, let space = Self.space(forPane: paneID, in: BrowserStore.shared.model) {
            event.spaceID = space.id; event.spaceName = space.name
        }
        record(scope: scope, event)
    }

    // MARK: - Tick

    /// Every 5s on main while the app is active: for each window's current
    /// tab, capture each pane according to its kind. Main-thread work here is
    /// a few dictionary reads and kicking off async WebKit snapshots.
    @MainActor
    func captureTick() {
        guard isActive else { return }
        #if os(macOS)
        guard NSApp.isActive else { return }
        #endif
        let state = BrowserStore.shared.model
        for window in state.windows.values {
            guard let tabID = window.currentTab, let tab = state.tabs[tabID], !tab.isPip else { continue }
            let space = state.profiles[window.profile].map { (id: $0.id.raw, name: $0.displayName) }
            for pane in tab.panes {
                guard let wc = BrowserStore.shared.existingWebContent(forId: pane.id), isEnabled(wc.datastoreUUID) else { continue }
                if let url = pane.info.url, let key = NativePageKey(url: url) {
                    switch key {
                    case .terminal: captureTerminal(wc, pane: pane, tabID: tabID, space: space)
                    case .agent(let agentKey, _): captureAgentChat(agentKey: agentKey, wc: wc, pane: pane, tabID: tabID, space: space)
                    default: break
                    }
                } else {
                    captureWebPane(wc, pane: pane, tabID: tabID, space: space)
                }
            }
        }
        captureChatThreads(state)
    }

    // MARK: - Web pages: snapshot → OCR → line diff

    /// One OCR in flight per pane; a tick that finds one running skips.
    private static var ocrInFlight = Set<String>()   // main-only
    private static var lastImageHash: [String: UInt64] = [:]   // ocrQueue-only

    func captureWebPane(_ wc: WebContent, pane: Pane, tabID: ID<Tab>, space: (id: String, name: String)? = nil) {
        #if os(macOS)
        guard let url = pane.info.url, Self.pageType(for: url) != "other",
              let webview = wc.wkWebview, webview.window != nil, !webview.isHiddenOrHasHiddenAncestor,
              webview.bounds.width > 50, webview.bounds.height > 50 else { return }
        let paneKey = pane.id.raw
        guard !Self.ocrInFlight.contains(paneKey) else { return }
        Self.ocrInFlight.insert(paneKey)
        let scope = wc.datastoreUUID
        let title = pane.info.title
        let tabRaw = tabID.raw
        let space = space ?? Self.space(forPane: pane.id, in: BrowserStore.shared.model)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: min(1400, Int(webview.bounds.width)))
        webview.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                Self.ocrInFlight.remove(paneKey)
                return
            }
            self.ocrQueue.async {
                defer { DispatchQueue.main.async { Self.ocrInFlight.remove(paneKey) } }
                let hash = Self.quickHash(cg)
                if Self.lastImageHash[paneKey] == hash { return }
                Self.lastImageHash[paneKey] = hash
                if Self.lastImageHash.count > 200 { Self.lastImageHash.removeAll() }
                let lines = Self.ocrLines(cg)
                guard !lines.isEmpty else { return }
                self.ingestLines(scope: scope, key: "screen:" + paneKey, lines: lines) { text in
                    var e = MemoryEvent(kind: "screen", pageType: Self.pageType(for: url), paneID: paneKey, tabID: tabRaw,
                                        url: url, title: title, text: text)
                    e.spaceID = space?.id; e.spaceName = space?.name
                    return e
                }
            }
        }
        #endif
    }

    /// FNV-1a over a strided sample of the pixel bytes: cheap change detection
    /// so an unchanged screen costs no OCR.
    static func quickHash(_ image: CGImage) -> UInt64 {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 0 }
        let count = CFDataGetLength(data)
        var h: UInt64 = 0xcbf29ce484222325
        let stride = max(1, count / 20000)
        var i = 0
        while i < count {
            h ^= UInt64(ptr[i])
            h = h &* 0x100000001b3
            i += stride
        }
        return h ^ UInt64(count)
    }

    /// Recognized text, one string per line, top-to-bottom then left-to-right.
    static func ocrLines(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        let observations = results.compactMap { obs -> (String, CGRect)? in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (s, obs.boundingBox)
        }
        // Vision's boundingBox origin is bottom-left; bucket rows by their
        // vertical center so same-line fragments get joined left-to-right.
        let sorted = observations.sorted { a, b in
            let ay = a.1.midY, by = b.1.midY
            if abs(ay - by) > 0.008 { return ay > by }
            return a.1.minX < b.1.minX
        }
        var lines: [String] = []
        var currentY: CGFloat = .nan
        var current: [String] = []
        for (text, box) in sorted {
            if currentY.isNaN || abs(box.midY - currentY) > 0.008 {
                if !current.isEmpty { lines.append(current.joined(separator: "  ")) }
                current = [text]
                currentY = box.midY
            } else {
                current.append(text)
            }
        }
        if !current.isEmpty { lines.append(current.joined(separator: "  ")) }
        return lines
    }

    // MARK: - Terminals

    /// Terminal lines go through the "stable for two ticks" diff: TUIs redraw
    /// spinners, timers and the input box every frame, and a plain diff logged
    /// each of those frames as new content.
    @MainActor
    func captureTerminal(_ wc: WebContent, pane: Pane, tabID: ID<Tab>, space: (id: String, name: String)? = nil) {
        #if os(macOS)
        guard let session = wc.overlayObject as? TerminalSession, session.isStarted else { return }
        let lines = session.snapshotTailLines(maxLines: 400)
        guard !lines.isEmpty else { return }
        let url = pane.info.url, title = pane.info.title, paneKey = pane.id.raw, tabRaw = tabID.raw
        let cwd = session.lastKnownCwd
        ingestLines(scope: wc.datastoreUUID, key: "term:" + paneKey, lines: lines, requireStable: true) { text in
            var e = MemoryEvent(kind: "terminal", pageType: "terminal", paneID: paneKey, tabID: tabRaw, url: url, title: title, text: text,
                                extra: ["cwd": cwd ?? NSNull()])
            e.spaceID = space?.id; e.spaceName = space?.name
            return e
        }
        #endif
    }

    // MARK: - Agent chats (agent tabs)

    private static var agentCursors: [String: Int] = [:]   // main-only

    @MainActor
    func captureAgentChat(agentKey: String, wc: WebContent, pane: Pane, tabID: ID<Tab>, space: (id: String, name: String)? = nil) {
        let session = AgentChatSession.session(forKey: agentKey)
        let since = Self.agentCursors[agentKey] ?? 0
        let fresh = session.messages.filter { $0.index >= since }
        guard let last = fresh.last else { return }
        Self.agentCursors[agentKey] = last.index + 1
        let text = Self.transcriptText(roles: fresh.map { ($0.role, $0.text, $0.toolName) })
        guard !text.isEmpty else { return }
        var event = MemoryEvent(kind: "agent", pageType: "agent", paneID: pane.id.raw, tabID: tabID.raw,
                                url: pane.info.url, title: pane.info.title, text: text, extra: ["agentKey": agentKey])
        event.spaceID = space?.id; event.spaceName = space?.name
        record(scope: wc.datastoreUUID, event)
    }

    // MARK: - Chat-mode space threads

    private static var chatThreadCursors: [ID<Profile>: String] = [:]   // main-only: last seen entry id

    func captureChatThreads(_ state: BrowserState) {
        let threads = ChatThreadStore.shared.model.threads
        for (profileID, thread) in threads {
            guard let profile = state.profiles[profileID], isEnabled(profile.dataStoreUUID), let last = thread.entries.last else { continue }
            let cursor = Self.chatThreadCursors[profileID]
            if cursor == last.id { continue }
            Self.chatThreadCursors[profileID] = last.id
            // First sighting: don't dump the whole history, just start tracking.
            guard let cursor else { continue }
            let fresh: [ChatThreadEntry]
            if let idx = thread.entries.firstIndex(where: { $0.id == cursor }) {
                fresh = Array(thread.entries[(idx + 1)...])
            } else {
                fresh = Array(thread.entries.suffix(20))
            }
            let text = Self.transcriptText(roles: fresh.map { ($0.role, $0.text, $0.toolName) })
            guard !text.isEmpty else { continue }
            var event = MemoryEvent(kind: "agent", pageType: "chat", title: profile.displayName, text: text,
                                    extra: ["spaceId": profileID.raw])
            event.spaceID = profileID.raw; event.spaceName = profile.displayName
            record(scope: profile.dataStoreUUID, event)
        }
    }

    static func transcriptText(roles: [(role: String, text: String, toolName: String?)]) -> String {
        roles.compactMap { m -> String? in
            switch m.role {
            case "user", "assistant", "peer", "error":
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : "\(m.role): \(t.prefix(4000))"
            case "tool_use":
                guard let name = m.toolName else { return nil }
                return "tool: \(name)"
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}
