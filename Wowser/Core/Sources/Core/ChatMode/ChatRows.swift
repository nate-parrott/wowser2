import SwiftUI

// Row views shared by the agent-tab chat (AgentChatOverlay) and the chat-mode
// sidebar (ChatSpaceSidebar). Both render a list of `ChatRowItem`s; the
// sidebar passes `compact: true` for its narrow column.

enum ChatRowItem: Identifiable, Equatable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case toolGroup(id: String, calls: [ChatToolCall])
    case tabCard(id: String, tabID: Core.ID<Tab>?, url: URL?, title: String?, note: String?)
    /// A message from another agent (subagent → coordinator, etc.).
    case peer(id: String, from: String?, text: String)
    case event(id: String, text: String)
    case error(id: String, text: String)
    case stopped(id: String)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .toolGroup(let id, _), .tabCard(let id, _, _, _, _),
             .peer(let id, _, _), .event(let id, _), .error(let id, _), .stopped(let id):
            return id
        }
    }

    var isTabCard: Bool { if case .tabCard = self { return true } else { return false } }
    /// Rows the transcript auto-scrolls to.
    var isJumpTarget: Bool {
        switch self {
        case .user, .assistant, .peer: return true
        default: return false
        }
    }
}

struct ChatToolCall: Equatable {
    var toolName: String?
    var input: String
}

/// Collapse a flat transcript into rows: adjacent tool calls become one group.
enum ChatRowBuilder {
    static func rows(fromAgentMessages messages: [BrowserJSAgentMessage], state: BrowserState) -> [ChatRowItem] {
        var out: [ChatRowItem] = []
        for m in messages {
            let id = String(m.index)
            switch m.role {
            case "user" where !m.text.isEmpty: out.append(.user(id: id, text: m.text))
            case "assistant" where !m.text.isEmpty: out.append(.assistant(id: id, text: m.text))
            case "peer": out.append(.peer(id: id, from: m.toolName, text: m.text))
            case "error" where !m.text.isEmpty: out.append(.error(id: id, text: m.text))
            case "stopped": out.append(.stopped(id: id))
            case "tool_use":
                let call = ChatToolCall(toolName: m.toolName, input: m.text)
                if case .toolGroup(let gid, let calls)? = out.last {
                    out[out.count - 1] = .toolGroup(id: gid, calls: calls + [call])
                } else {
                    out.append(.toolGroup(id: id, calls: [call]))
                }
            case "tab_card":
                let paneID = ID<WebContent>(raw: m.text)
                let tabID = state.paneToTabMapping[paneID]
                let pane = state.pane(forId: paneID)
                out.append(.tabCard(id: id, tabID: tabID, url: pane?.info.url ?? m.toolName.flatMap(URL.init(string:)), title: pane?.info.title, note: nil))
            default: break
            }
        }
        return out
    }

    static func rows(fromThreadEntries entries: [ChatThreadEntry]) -> [ChatRowItem] {
        var out: [ChatRowItem] = []
        for e in entries {
            switch e.role {
            case "user" where !e.text.isEmpty: out.append(.user(id: e.id, text: e.text))
            case "assistant" where !e.text.isEmpty: out.append(.assistant(id: e.id, text: e.text))
            case "peer": out.append(.peer(id: e.id, from: e.toolName, text: e.text))
            case "event": out.append(.event(id: e.id, text: e.text))
            case "error" where !e.text.isEmpty: out.append(.error(id: e.id, text: e.text))
            case "stopped": out.append(.stopped(id: e.id))
            case "tool_use":
                let call = ChatToolCall(toolName: e.toolName, input: e.text)
                if case .toolGroup(let gid, let calls)? = out.last {
                    out[out.count - 1] = .toolGroup(id: gid, calls: calls + [call])
                } else {
                    out.append(.toolGroup(id: e.id, calls: [call]))
                }
            case "tab_card":
                out.append(.tabCard(id: e.id, tabID: e.tabID, url: e.url, title: e.title, note: e.text.nilIfEmpty))
            default: break
            }
        }
        return out
    }
}

// MARK: - Row view

struct ChatRowView: View {
    var item: ChatRowItem
    var compact: Bool
    var windowID: ID<WindowState>?
    /// Called for markdown links / images the user clicks.
    var openURL: (URL) -> Void
    /// For `.user` rows in the sidebar: the turn's collapsed state and the
    /// chevron action. Nil hides the chevron.
    var turnCollapsed: Bool? = nil
    var onToggleTurn: (() -> Void)? = nil

    var body: some View {
        switch item {
        case .user(_, let text):
            ChatUserBubble(text: text, compact: compact, turnCollapsed: turnCollapsed, onToggleTurn: onToggleTurn)
        case .assistant(_, let text):
            ChatMarkdownBody(text: text, compact: compact, openURL: openURL)
        case .toolGroup(_, let calls):
            ChatToolGroupRow(calls: calls)
        case .tabCard(_, let tabID, let url, let title, let note):
            ChatTabCard(tabID: tabID, url: url, title: title, note: note, windowID: windowID, hideIfClosed: compact)
        case .peer(_, let from, let text):
            VStack(alignment: .leading, spacing: 3) {
                Text(from.map { "From \($0)" } ?? "From another agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ChatMarkdownBody(text: text, compact: compact, openURL: openURL)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.35)).frame(width: 2)
                    }
            }
        case .event(_, let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .error(_, let text):
            Text(text)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .stopped:
            Text("Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ChatUserBubble: View {
    var text: String
    var compact: Bool
    var turnCollapsed: Bool? = nil
    var onToggleTurn: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: compact ? 24 : 48)
            if let onToggleTurn {
                let collapsed = turnCollapsed ?? false
                Button(action: onToggleTurn) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show this turn's replies and tabs" : "Hide this turn's replies and tabs")
            }
            Text(text)
                .font(compact ? .system(size: 13.5) : .body)
                .textSelection(.enabled)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 6 : 9)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        }
    }
}

/// Assistant text: inline markdown, with `![alt](url)` images rendered
/// inline. Links and images route through `openURL`.
struct ChatMarkdownBody: View {
    var text: String
    var compact: Bool
    var openURL: (URL) -> Void

    private enum Block: Identifiable {
        case text(String)
        case image(URL, alt: String)
        case code(String)
        var id: String {
            switch self {
            case .text(let s): return "t:" + s.prefix(64)
            case .image(let u, _): return "i:" + u.absoluteString
            case .code(let s): return "c:" + s.prefix(64)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    markdownText(s)
                        .font(compact ? .system(size: 13.5) : .body)
                        .lineSpacing(compact ? 4 : 4.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.openURL, OpenURLAction { url in
                            openURL(url)
                            return .handled
                        })
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: compact ? 12 : 13, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .image(let url, let alt):
                    Button(action: { openURL(url) }) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                            case .failure:
                                Label(alt.nilIfEmpty ?? url.absoluteString, systemImage: "photo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            default:
                                Color.secondary.opacity(0.1).frame(height: 80)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: compact ? 160 : 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(alt.nilIfEmpty ?? url.absoluteString)
                }
            }
        }
    }

    private var blocks: [Block] {
        // Fenced code blocks first: the inline-only markdown parser would
        // treat ``` as a code span and collapse its newlines to spaces.
        var out: [Block] = []
        var prose = ""
        var code: String? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code {
                    out.append(contentsOf: Self.imageBlocks(prose)); prose = ""
                    out.append(.code(c.hasSuffix("\n") ? String(c.dropLast()) : c))
                    code = nil
                } else {
                    code = ""
                }
            } else if code != nil {
                code! += line + "\n"
            } else {
                prose += line + "\n"
            }
        }
        if let c = code { prose += "```\n" + c }  // unterminated fence (still streaming): show as prose
        out.append(contentsOf: Self.imageBlocks(prose))
        return out.isEmpty ? [.text(text)] : out
    }

    /// Split out image markdown so it can render as an actual image.
    private static func imageBlocks(_ raw: String) -> [Block] {
        let text = raw.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#) else { return [.text(text)] }
        let ns = text as NSString
        var out: [Block] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(chunk)) }
            }
            let alt = ns.substring(with: match.range(at: 1))
            if let url = URL(string: ns.substring(with: match.range(at: 2))) {
                out.append(.image(url, alt: alt))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let chunk = ns.substring(from: cursor)
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(chunk)) }
        }
        return out.isEmpty ? [.text(text)] : out
    }

    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: Self.linkifyBareURLs(string),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    /// Wrap bare `http(s)://…` URLs in markdown link syntax so they render as
    /// clickable links even when the model forgot to. URLs already inside a
    /// link target `(…)`, an autolink `<…>`, or a `[…]` label are left alone;
    /// trailing punctuation stays outside the link.
    static func linkifyBareURLs(_ text: String) -> String {
        guard text.contains("://"),
              let regex = try? NSRegularExpression(pattern: #"(?<![\(<\[\w])https?://[^\s<>\)\]]+"#) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var url = ns.substring(with: match.range)
            var trailing = ""
            while let last = url.last, ".,;:!?'\"".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                url.removeLast()
            }
            out += "[\(url)](\(url))" + trailing
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

/// A run of adjacent tool calls, collapsed to one quiet line; click to expand
/// and see each call's tool + input.
struct ChatToolGroupRow: View {
    var calls: [ChatToolCall]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { expanded.toggle() }) {
                Text(calls.count == 1 ? "Used 1 tool" : "Used \(calls.count) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline(expanded)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.friendlyToolName(call.toolName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !call.input.isEmpty {
                                Text(call.input.prefix(600))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    static func friendlyToolName(_ name: String?) -> String {
        switch name {
        case "run_browser_js": return "Drove the browser"
        case "done": return "Wrapped up"
        case .some(let other): return other
        case nil: return "Tool"
        }
    }
}

// MARK: - Tab card

/// A tab, rendered with the real sidebar tab row so it looks and behaves like
/// one (click to activate, hover for close, drag, context menu). If the tab
/// has since been closed, a muted stub is shown (clicking it reopens the URL)
/// — or, with `hideIfClosed`, the card disappears entirely.
struct ChatTabCard: View {
    var tabID: ID<Tab>?
    var url: URL?
    var title: String?
    var note: String?
    var windowID: ID<WindowState>?
    var hideIfClosed = false

    var body: some View {
        if let tabID, let windowID {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Bool? in
                guard state.tabs[tabID] != nil else { return nil }
                return state.windows[windowID]?.currentTab == tabID
            }) { isSelected in
                if let isSelected {
                    card {
                        RegularTabRow(tabID: tabID, isSelected: isSelected, windowID: windowID)
                            .overlay { if !isSelected { unselectedBorder } }
                    }
                } else if !hideIfClosed {
                    card { ClosedTabStub(url: url, title: title, windowID: windowID).overlay { unselectedBorder } }
                }
            }
        } else if !hideIfClosed {
            card { ClosedTabStub(url: url, title: title, windowID: windowID).overlay { unselectedBorder } }
        }
    }

    /// Hairline around cards that aren't the current tab, so they read as
    /// cards in the thread rather than plain rows. Inset to match the
    /// selected row's glass background, which TabStyleButtonModifier pads by
    /// 6pt horizontally and 2pt vertically.
    private var unselectedBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .allowsHitTesting(false)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            content()
        }
    }
}

/// Placeholder for a card whose tab was closed. Click to reopen.
private struct ClosedTabStub: View {
    var url: URL?
    var title: String?
    var windowID: ID<WindowState>?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: url.map { .favicon($0.inferredFaviconURL) } ?? .empty)
                .opacity(0.5)
            Text(title?.nilIfEmpty ?? url?.hostWithoutWWW ?? "Closed tab")
                .lineLimit(1)
                .opacity(0.5)
            Spacer()
            if hovered {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.secondary)
                    .padding(6)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: UIConstants.macTabHeight)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .modifier(TabStyleButtonModifier(isSelected: false, pressed: reopen))
        .help(url?.absoluteString ?? "")
    }

    private func reopen() {
        guard let url, let windowID else { return }
        BrowserStore.shared.modify { st in
            st.openTab(url: url, activate: true, windowID: windowID)
        }
    }
}
