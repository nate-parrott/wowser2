import Foundation

// A plain-text "you are here" for MCP agents: which terminal tab the agent is
// running in, what else is open in that tab's space, and what other spaces
// exist. Served in the `initialize` response's `instructions` (so Claude Code
// has it in its system prompt before the first tool call) and on demand via
// the `get_browser_context` tool.

extension BrowserState {
    /// `originPaneID` is the terminal pane the MCP client process lives in, when
    /// `TerminalProcessLookup` could identify one. Without it, the summary
    /// falls back to the most-recently-active window and its current space.
    func agentOrientation(originPaneID: ID<WebContent>?) -> String {
        var lines: [String] = []

        // Resolve the vantage point: origin pane → its window + space; else the
        // most recently active window and whatever space it's showing.
        let origin = originPaneID.flatMap { pid in originContext(paneID: pid).map { (pane: pid, window: $0.windowID, space: $0.spaceID) } }
        let windowID: ID<WindowState>?
        let spaceID: ID<Profile>?
        if let origin {
            windowID = origin.window
            spaceID = origin.space
            lines.append("You are running in a terminal tab (tabId \(origin.pane.raw)) inside this browser.")
        } else {
            let win = windows.values.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }.first
            windowID = win?.id
            spaceID = win?.profile
            lines.append("Could not tell which browser tab you're running in; showing the most recently active window instead.")
        }

        guard let windowID, let win = windows[windowID], let spaceID, let space = profiles[spaceID] else {
            lines.append("No browser windows are open.")
            return lines.joined(separator: "\n")
        }

        // The space the agent's tab lives in.
        var header = "Your space: \(spaceLabel(space))"
        if win.profile != spaceID, let showing = profiles[win.profile] {
            header += " (the window is currently showing \(spaceLabel(showing)) instead)"
        }
        lines.append(header)

        let tabIDs = win.profile == spaceID ? win.tabs : (win.perProfileData[spaceID]?.tabs ?? [])
        let currentTabID = win.profile == spaceID ? win.currentTab : win.perProfileData[spaceID]?.currentTab
        let favorites = (space.manualFavorites + space.autoFavorites).filter { tabs[$0] != nil }
        let listed = favorites + tabIDs.filter { !favorites.contains($0) }
        if listed.isEmpty {
            lines.append("Tabs in this space: none")
        } else {
            lines.append("Tabs in this space (tabId — title — url):")
            for tabID in listed {
                guard let tab = tabs[tabID] else { continue }
                if let folder = tab.folder {
                    lines.append("  • [folder \(tabID.raw)] \(folder.name) — \(folder.tabs.count) tab\(folder.tabs.count == 1 ? "" : "s")")
                    for memberID in folder.tabs {
                        guard let member = tabs[memberID] else { continue }
                        for pane in member.panes where !pane.isGhost {
                            let open = folder.openTabs.contains(memberID)
                            let current = memberID == currentTabID && member.focusedPane?.id == pane.id
                            lines.append("      ◦ \(paneLine(pane, tab: member))  [in folder\(open ? "" : ", closed")\(current ? ", current" : "")]")
                        }
                    }
                    continue
                }
                for pane in tab.panes where !pane.isGhost {
                    var flags: [String] = []
                    if tabID == currentTabID, tab.focusedPane?.id == pane.id { flags.append("current") }
                    if pane.id == origin?.pane { flags.append("this terminal") }
                    if favorites.contains(tabID) { flags.append("favorite") }
                    if tab.panes.count > 1 { flags.append("split") }
                    let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
                    lines.append("  • \(paneLine(pane, tab: tab))\(suffix)")
                }
            }
        }

        // Other spaces, in carousel order.
        let others = visibleProfiles.filter { $0.id != spaceID }
        if !others.isEmpty {
            lines.append("Other spaces (spaceId — name — tab count):")
            for other in others {
                let count = (win.perProfileData[other.id]?.tabs ?? []).filter { tabs[$0] != nil }.count
                lines.append("  • \(other.id.raw) — \(other.displayName) — \(count) tab\(count == 1 ? "" : "s")")
            }
        }

        // Other windows, briefly.
        let otherWindows = windows.values.filter { $0.id != windowID }
        if !otherWindows.isEmpty {
            let descriptions = otherWindows.map { w -> String in
                let name = profiles[w.profile]?.displayName ?? "?"
                return "\(w.id.raw) (showing \(name), \(w.tabs.count) tabs)"
            }
            lines.append("Other windows: \(descriptions.joined(separator: "; "))")
        }

        lines.append("Use `run_browser_js` with `browser.tabs.*` / `browser.spaces.*` to act on these ids; call `get_browser_context` again for a fresh view.")
        return lines.joined(separator: "\n")
    }

    private func spaceLabel(_ space: Profile) -> String {
        "\"\(space.displayName)\" (spaceId \(space.id.raw))"
    }

    private func paneLine(_ pane: Pane, tab: Tab) -> String {
        let url = pane.info.url
        let kind: String? = url.flatMap { u in
            if u.scheme == TangSchemeHandler.scheme { return "webapp" }
            return NativePageKey(url: u)?.kindString
        }
        let title = (tab.customTitle?.nilIfEmpty ?? pane.info.title?.nilIfEmpty ?? kind ?? "Untitled")
        var s = "\(pane.id.raw) — \(title)"
        if let kind { s += " (\(kind))" }
        if let url, kind == nil { s += " — \(url.absoluteString)" }
        return s
    }
}
