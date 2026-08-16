import SwiftUI

// Native chat UI for agent tabs (NativePageKey.agent). User messages render as
// liquid-glass capsules with iMessage-style tails; the agent's replies are
// plain text on the background. Transcript + scroll position live in
// AgentChatSession so they survive tab switches and view remounts.

struct AgentChatOverlay: View {
    var sessionKey: String
    var initialQuery: String?
    var webContent: WebContent

    @Environment(\.windowID) private var windowID

    var body: some View {
        let content = AgentChatContent(
            session: AgentChatSession.session(forKey: sessionKey),
            flavor: .flavor(forKey: sessionKey),
            paneID: webContent.id,
            windowID: windowID
        )
        #if os(macOS)
        WrapsContentReportingFirstResponder(target: .agentChat(webContent.id)) {
            content
        }
        #else
        content
        #endif
    }
}

private struct AgentChatContent: View {
    @ObservedObject var session: AgentChatSession
    var flavor: AgentFruitFlavor
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>?

    @State private var scrollPos = ScrollPosition()
    @State private var viewportHeight: CGFloat = 400
    @State private var distanceFromBottom: CGFloat = 0
    @State private var lastJumpedToIndex: Int?
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
        .background(Color("Background", bundle: .module))
        // Links in the transcript open beside the chat (or navigate the
        // existing split), never navigating the chat tab itself away.
        .environment(\.openURL, OpenURLAction { url in
            AgentChatTabs.openLink(url, fromAgentPane: paneID)
            return .handled
        })
        .onAppear {
            session.attachIfNeeded(ownPaneID: paneID)
            if let saved = session.savedScrollY {
                scrollPos.scrollTo(y: saved)
            }
        }
        .onReceiveFocusSnap(windowID: windowID) { snap in
            if snap.target == .agentChat(paneID) {
                inputFocused = true
            }
        }
    }

    // MARK: - Transcript

    /// Rows worth rendering, keyed by transcript index.
    private var visibleMessages: [BrowserJSAgentMessage] {
        session.messages.filter { msg in
            switch msg.role {
            case "user", "assistant", "error", "stopped": return !msg.text.isEmpty
            case "tool_use": return true
            default: return false // thinking, tool_result
            }
        }
    }

    /// The message whose top we auto-scroll to: the latest user or assistant
    /// message (tool chips don't warrant a jump).
    private var latestJumpTarget: Int? {
        visibleMessages.last(where: { $0.role == "user" || $0.role == "assistant" })?.index
    }

    /// Visible messages with runs of adjacent tool calls collapsed into groups.
    private var rows: [AgentChatRowItem] {
        var out: [AgentChatRowItem] = []
        for msg in visibleMessages {
            if msg.role == "tool_use", case .toolGroup(let id, let calls)? = out.last {
                out[out.count - 1] = .toolGroup(id: id, calls: calls + [msg])
            } else if msg.role == "tool_use" {
                out.append(.toolGroup(id: msg.index, calls: [msg]))
            } else {
                out.append(.message(msg))
            }
        }
        return out
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    switch row {
                    case .message(let msg):
                        AgentChatRow(message: msg)
                            .id(msg.index)
                    case .toolGroup(_, let calls):
                        ToolGroupRow(calls: calls)
                            .id(row.id)
                    }
                }
                if session.isWorking {
                    workingIndicator
                }
                if let errorText = session.errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                // Room at the bottom so the top of the latest message can sit
                // at the top of the viewport while its reply streams in below.
                Color.clear.frame(height: max(0, viewportHeight - 120))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPos)
        .onScrollGeometryChange(for: ScrollGeometryInfo.self) { geo in
            ScrollGeometryInfo(
                offsetY: geo.contentOffset.y,
                viewportHeight: geo.containerSize.height,
                distanceFromBottom: geo.contentSize.height - geo.containerSize.height - geo.contentOffset.y
            )
        } action: { _, info in
            session.savedScrollY = info.offsetY
            viewportHeight = info.viewportHeight
            distanceFromBottom = info.distanceFromBottom
        }
        .onChange(of: latestJumpTarget) { _, newValue in
            guard let newValue, newValue != lastJumpedToIndex else { return }
            let isOwnSend = visibleMessages.last(where: { $0.index == newValue })?.role == "user"
            // Scroll only if necessary: don't yank the transcript if the user
            // has scrolled up to read older messages (unless they just sent).
            if isOwnSend || distanceFromBottom < viewportHeight * 1.5 {
                lastJumpedToIndex = newValue
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollPos.scrollTo(id: newValue, anchor: .top)
                }
            }
        }
    }

    private var workingIndicator: some View {
        HStack(spacing: 8) {
            AgentFruitIcon(flavor: flavor, working: true, size: 18)
            Text("Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { sendInput() }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

            if session.isWorking {
                Button(action: { session.interrupt() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: { sendInput() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        session.send(text: text)
    }
}

private struct ScrollGeometryInfo: Equatable {
    var offsetY: CGFloat
    var viewportHeight: CGFloat
    var distanceFromBottom: CGFloat
}

// MARK: - Rows

private enum AgentChatRowItem: Identifiable {
    case message(BrowserJSAgentMessage)
    case toolGroup(id: Int, calls: [BrowserJSAgentMessage])

    var id: Int {
        switch self {
        case .message(let msg): return msg.index
        case .toolGroup(let id, _): return id
        }
    }
}

/// A run of adjacent tool calls, collapsed to one quiet line; click to expand
/// and see each call's tool + input.
private struct ToolGroupRow: View {
    var calls: [BrowserJSAgentMessage]
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
                    ForEach(calls, id: \.index) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friendlyToolName(call.toolName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !call.text.isEmpty {
                                Text(call.text.prefix(600))
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

    private func friendlyToolName(_ name: String?) -> String {
        switch name {
        case "run_browser_js": return "Drove the browser"
        case "done": return "Wrapped up"
        case .some(let other): return other
        case nil: return "Tool"
        }
    }
}

private struct AgentChatRow: View {
    var message: BrowserJSAgentMessage

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case "assistant":
            markdownText(message.text)
                .lineSpacing(4.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "stopped":
            Text("Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case "error":
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}

