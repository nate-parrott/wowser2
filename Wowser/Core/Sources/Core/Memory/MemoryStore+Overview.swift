import Foundation

// The "memory overview": a per-scope markdown document summarizing what the
// event log says about the user. Editable by hand in Settings › Memory, by an
// agent through `browser.memory.setOverview`, and regenerated on request by a
// headless agent that reads the log with `browser.memory.query`.

public struct MemoryOverviewInfo: Equatable {
    public enum Status: String, Equatable { case idle, queued, running, error }
    public var text: String = ""
    public var updatedAt: Date?
    public var status: Status = .idle
    public var statusDetail: String?
    public var loaded = false
}

final class OverviewRun {
    var task: Task<Void, Never>?
    var startedAt = Date()
}

extension MemoryStore {

    /// Load text + updated date from the DB and publish it. Main thread.
    public func loadOverview(scope: UUID) {
        Task {
            let (text, date): (String, Date?) = (try? await perform(scope: scope) { db in
                let text = (try? db.scalar("SELECT value FROM meta WHERE key = 'overview'")) as? String ?? ""
                let iso = (try? db.scalar("SELECT value FROM meta WHERE key = 'overview_updated_at'")) as? String
                return (text, iso.flatMap { ISO8601DateFormatter().date(from: $0) })
            }) ?? ("", nil)
            await MainActor.run {
                var info = self.overviews[scope] ?? MemoryOverviewInfo()
                info.text = text
                info.updatedAt = date
                info.loaded = true
                self.overviews[scope] = info
            }
        }
    }

    /// Persist a new overview and stamp the edit date. Main thread.
    public func setOverview(scope: UUID, text: String) {
        let now = Date()
        var info = overviews[scope] ?? MemoryOverviewInfo()
        info.text = text
        info.updatedAt = now
        info.loaded = true
        overviews[scope] = info
        let iso = ISO8601DateFormatter().string(from: now)
        queue.async {
            guard let db = self.db(for: scope) else { return }
            try? db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('overview', ?)", [text])
            try? db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('overview_updated_at', ?)", [iso])
        }
    }

    public func overviewInfo(scope: UUID) -> MemoryOverviewInfo {
        overviews[scope] ?? MemoryOverviewInfo()
    }

    /// Queue a regeneration. The agent starts after a short delay so repeated
    /// presses coalesce; it's guaranteed to start well within five minutes.
    public func requestOverviewRegeneration(scope: UUID) {
        assert(Thread.isMainThread)
        guard isEnabled(scope) else { return }
        if let run = overviewRuns[scope], run.task != nil { return }
        var info = overviews[scope] ?? MemoryOverviewInfo()
        info.status = .queued
        info.statusDetail = "Starting shortly…"
        overviews[scope] = info
        let run = OverviewRun()
        overviewRuns[scope] = run
        run.task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.runOverviewAgent(scope: scope)
            self.overviewRuns[scope] = nil
        }
    }

    private func setStatus(_ status: MemoryOverviewInfo.Status, _ detail: String?, scope: UUID) {
        var info = overviews[scope] ?? MemoryOverviewInfo()
        info.status = status
        info.statusDetail = detail
        overviews[scope] = info
    }

    @MainActor
    private func runOverviewAgent(scope: UUID) async {
        setStatus(.running, "Agent is reading the memory log…", scope: scope)
        let existing = overviews[scope]?.text ?? ""
        let previousDate = overviews[scope]?.updatedAt
        let scopeNames = Self.scopes(in: BrowserStore.shared.model).first(where: { $0.id == scope })?.names.joined(separator: ", ") ?? scope.uuidString
        let dateText = previousDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "never"
        let system = """
        You maintain the "memory overview" for the browser space(s) "\(scopeNames)" (memory scope id `\(scope.uuidString)`). \
        The overview is a concise markdown briefing that another assistant reads first to understand this user: who they are, \
        what they're working on, sites and tools they use, ongoing threads (projects, purchases, research, travel), habits, and \
        anything recently important. Be concrete (names, URLs, dates) and prefer recent activity. 400–900 words.

        Workflow, using `run_browser_js`:
        1. `await browser.memory.schema()` — read the table layout.
        2. Explore with `await browser.memory.query({ scope: '\(scope.uuidString)', sql: '...' })` (read-only SELECT; LIMIT everything; \
           use substr(text,1,300) for previews). Start broad: visits grouped by domain and day, recent titles, FTS searches for \
           topics you spot, terminal/agent/typed events. Several queries are expected.
        3. Write the new overview, keeping still-relevant parts of the previous one, then call \
           `await browser.memory.setOverview({ scope: '\(scope.uuidString)', text })`. This step is REQUIRED — the overview is \
           only saved through that call. Finish with a one-line summary of what changed.

        Do not open tabs or navigate; do not present anything to the user. Do not include secrets (passwords, tokens, card numbers) \
        even if they appear in the log.
        """
        let prompt = """
        Update the memory overview. It was last updated: \(dateText).

        Current overview:
        ---
        \(existing.isEmpty ? "(empty)" : existing)
        ---
        """
        let options = BrowserJSAgentCreateOptions(name: "Memory overview: \(scopeNames)", effort: "medium", systemPrompt: system)
        let startedAt = Date()
        do {
            let id = try await BrowserAgentManager.shared.create(options: options)
            try await BrowserAgentManager.shared.send(id: id, text: prompt, images: [])
            var since = 0
            var finalText: String?
            var isError = false
            while Date().timeIntervalSince(startedAt) < 15 * 60 {
                let res = try await BrowserAgentManager.shared.awaitIdle(id: id, timeoutMs: 30_000, since: since)
                since = res.nextIndex
                if let last = res.messages.last(where: { $0.role == "tool_use" || $0.role == "assistant" }) {
                    setStatus(.running, last.role == "tool_use" ? "Querying memory…" : String(last.text.prefix(80)), scope: scope)
                }
                if res.done {
                    finalText = res.text
                    isError = res.isError
                    break
                }
            }
            // Pick up whatever the agent saved via browser.memory.setOverview.
            loadOverview(scope: scope)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let updated = overviews[scope]?.updatedAt
            let saved = updated != nil && updated! > startedAt
            if isError {
                setStatus(.error, finalText ?? "Agent failed", scope: scope)
            } else if !saved, let finalText, finalText.count > 200 {
                // Agent wrote the overview in its reply instead of calling the tool.
                setOverview(scope: scope, text: finalText)
                setStatus(.idle, "Updated (from agent reply)", scope: scope)
            } else if saved {
                setStatus(.idle, "Updated", scope: scope)
            } else {
                setStatus(.error, "Agent finished without saving an overview", scope: scope)
            }
        } catch {
            setStatus(.error, error.localizedDescription, scope: scope)
        }
    }
}
