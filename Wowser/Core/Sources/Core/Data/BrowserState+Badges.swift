import Foundation

// MARK: - Tab badges
//
// A pane's `info.badged` bit marks a tab that finished something while the
// user wasn't looking at it. All writes to `pane.info` that could represent a
// running → idle transition go through `updatePaneInfo`, which (a) preserves
// the bit across wholesale copies from the live WebContent and (b) sets it
// when the transition happens on a tab that isn't currently visible.

extension WebContent.Info {
    enum ClaudeCodeState: Equatable {
        case running
        case idle
    }

    /// Spinner glyphs Claude Code puts at the front of the terminal title
    /// while it's working, e.g. "◑ MCP contextual welcome message".
    static let claudeCodeRunningGlyphs: Set<Character> = ["◐", "◑", "◒", "◓"]
    /// Glyph Claude Code uses at the prompt: "✳ Claude Code".
    static let claudeCodeIdleGlyph: Character = "✳"

    /// True when the terminal's foreground process is `claude` (Claude Code).
    var terminalIsRunningClaudeCode: Bool {
        terminalForegroundCommand?.split(separator: " ").first == "claude"
    }

    /// Native terminal tabs only: what Claude Code says it's doing, read from
    /// the title it sets over OSC. nil when Claude Code isn't the foreground
    /// process or its title doesn't carry a recognizable state glyph.
    var claudeCodeState: ClaudeCodeState? {
        guard terminalIsRunningClaudeCode,
              let first = title?.trimmingCharacters(in: .whitespaces).first else { return nil }
        if WebContent.Info.claudeCodeRunningGlyphs.contains(first) { return .running }
        if first == WebContent.Info.claudeCodeIdleGlyph { return .idle }
        return nil
    }

    /// True when `new` shows this pane just stopped working: Claude Code went
    /// from a spinner title to idle/exited, or an agent tab finished its turn.
    static func finishedWork(previous: WebContent.Info, new: WebContent.Info) -> Bool {
        // Agent tabs: mid-turn → done.
        if previous.agentIsWorking == true, new.agentIsWorking != true {
            return true
        }
        // Claude Code in a terminal: spinner → idle prompt, or claude exited.
        // A nil title is the transient wiped state right after the webview
        // re-reports metadata (native tabs own their title), not a real
        // transition, so ignore it.
        if previous.claudeCodeState == .running, new.claudeCodeState != .running, new.title != nil {
            return true
        }
        return false
    }
}

extension BrowserState {
    /// Is this tab the current tab of any window? Badges aren't set on tabs
    /// the user is already looking at.
    func tabIsVisible(_ tabID: ID<Tab>) -> Bool {
        windows.values.contains { $0.currentTab == tabID }
    }

    /// The one way to write a pane's `info` when the write might carry a
    /// running → idle transition (wholesale copies from the WebContent, the
    /// terminal title/command writes, the agent working-state writes).
    /// Preserves the badge bit and sets it when work finishes off-screen.
    mutating func updatePaneInfo(forWebContentId id: ID<WebContent>, _ block: (inout WebContent.Info) -> Void) {
        let visible = paneToTabMapping[id].map(tabIsVisible) ?? true
        modifyPaneAndTab(forWebContentId: id) { pane, _ in
            let previous = pane.info
            var new = previous
            block(&new)
            // The live WebContent never sets `badged`; state owns it.
            new.badged = previous.badged
            if !visible, WebContent.Info.finishedWork(previous: previous, new: new) {
                new.badged = true
            }
            pane.info = new
        }
    }

    /// Turn the badge on or off for every pane in a tab.
    mutating func setBadge(_ badged: Bool, forTabId tabID: ID<Tab>) {
        modifyTab(id: tabID) { tab in
            for pane in tab.panes.asArray where (pane.info.badged ?? false) != badged {
                tab.panes[pane.id]?.info.badged = badged ? true : nil
            }
        }
    }

    /// The user opened the tab: drop the badge and, on panes whose agent lease
    /// already ended, the "Agent was using this tab" residue. A pane still
    /// under lease keeps its marker — the agent really is (or was just) on it.
    mutating func clearAttentionMarkers(forTabId tabID: ID<Tab>) {
        guard let tab = tabs[tabID] else { return }
        let needsChange = tab.panes.asArray.contains {
            $0.info.badged == true || ($0.agentActiveUntil == nil && $0.agentLastUsedAt != nil)
        }
        guard needsChange else { return }
        modifyTab(id: tabID) { tab in
            for pane in tab.panes.asArray {
                tab.panes[pane.id]?.info.badged = nil
                if pane.agentActiveUntil == nil {
                    tab.panes[pane.id]?.agentLastUsedAt = nil
                    tab.panes[pane.id]?.agentUseStale = nil
                }
            }
        }
    }
}

extension Pane {
    /// What the sidebar should say about agent use of this pane, if anything.
    enum AgentUse: Equatable {
        case active   // lease live and touched recently
        case past     // lease live but stale, or ended without the user opening the tab since
    }

    var agentUse: AgentUse? {
        if agentActiveUntil != nil {
            return agentUseStale == true ? .past : .active
        }
        return agentLastUsedAt != nil ? .past : nil
    }

    /// Sidebar badge for this pane: a cursor when an agent is or was driving
    /// it, else a dot when it finished work off-screen.
    var badge: TabAppearance.Badge? {
        if agentUse != nil { return .cursor }
        if info.badged == true { return .dot }
        return nil
    }
}
