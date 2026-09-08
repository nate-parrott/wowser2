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
    @State private var lastJumpedToIndex: String?
    @State private var didAppear = false
    // Saved offset we still owe the scroll view: applied once the transcript has
    // laid out enough height to honor it. Until then, don't overwrite
    // session.savedScrollY with the clamped-to-top offset.
    @State private var pendingScrollRestoreY: CGFloat?
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
        .background(Color("Background", bundle: .module))
        .onAppear {
            session.attachIfNeeded(ownPaneID: paneID)
            lastJumpedToIndex = latestJumpTarget
            if let saved = session.savedScrollY {
                pendingScrollRestoreY = saved
                scrollPos.scrollTo(y: saved)
            } else if let target = latestJumpTarget {
                // Reopening an existing transcript with no remembered position:
                // land on the latest message immediately, no animation.
                scrollPos.scrollTo(id: target, anchor: .top)
            }
            didAppear = true
        }
        .onReceiveFocusSnap(windowID: windowID) { snap in
            if snap.target == .agentChat(paneID) {
                inputFocused = true
            }
        }
    }

    // MARK: - Transcript

    private var rows: [ChatRowItem] {
        ChatRowBuilder.rows(fromAgentMessages: session.messages, state: BrowserStore.shared.model)
    }

    /// The message whose top we auto-scroll to: the latest user or assistant
    /// message (tool chips don't warrant a jump).
    private var latestJumpTarget: String? {
        rows.last(where: { $0.isJumpTarget })?.id
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    ChatRowView(item: row, compact: false, windowID: windowID, openURL: { url in
                        AgentChatTabs.openLink(url, fromAgentPane: paneID)
                    })
                    .id(row.id)
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
            viewportHeight = info.viewportHeight
            distanceFromBottom = info.distanceFromBottom
            guard didAppear else { return }
            if let pending = pendingScrollRestoreY {
                let maxOffset = info.offsetY + info.distanceFromBottom
                guard maxOffset > 0 else { return } // transcript hasn't laid out yet
                pendingScrollRestoreY = nil
                let target = min(pending, maxOffset)
                if abs(info.offsetY - target) >= 2 {
                    scrollPos.scrollTo(y: target)
                    return
                }
            }
            session.savedScrollY = info.offsetY
        }
        .onChange(of: latestJumpTarget) { _, newValue in
            guard let newValue, newValue != lastJumpedToIndex else { return }
            let isOwnSend: Bool = { if case .user? = rows.last(where: { $0.id == newValue }) { return true }; return false }()
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
            Button("Stop") { session.interrupt() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .underline()
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
