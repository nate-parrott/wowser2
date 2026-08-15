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
        .onAppear {
            session.attachIfNeeded()
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

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(visibleMessages, id: \.index) { msg in
                    AgentChatRow(message: msg)
                        .id(msg.index)
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
                    .glassEffect(.regular, in: ChatBubbleWithTail())
                    .padding(.trailing, 2)
            }
        case "assistant":
            markdownText(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "tool_use":
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                Text(friendlyToolName(message.toolName))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func friendlyToolName(_ name: String?) -> String {
        switch name {
        case "run_browser_js": return "Driving the browser"
        case "done": return "Wrapping up"
        case .some(let other): return "Using \(other)"
        case nil: return "Using a tool"
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

/// A message capsule with an iMessage-style tail curling out of the
/// bottom-trailing corner. The tail occupies the trailing ~6pt of the rect.
struct ChatBubbleWithTail: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 6
        let bubble = CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
        let radius = min(19, bubble.height / 2)
        var path = Path(roundedRect: bubble, cornerRadius: radius, style: .continuous)

        var tailPath = Path()
        tailPath.move(to: CGPoint(x: bubble.maxX - radius, y: rect.maxY))
        tailPath.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: bubble.maxX - 1, y: rect.maxY)
        )
        tailPath.addQuadCurve(
            to: CGPoint(x: bubble.maxX, y: rect.maxY - radius * 0.85),
            control: CGPoint(x: bubble.maxX + 1.5, y: rect.maxY - radius * 0.3)
        )
        tailPath.closeSubpath()
        path.addPath(tailPath)
        return path
    }
}
