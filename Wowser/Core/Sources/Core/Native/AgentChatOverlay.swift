import SwiftUI
import UniformTypeIdentifiers

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
    @State private var attachments: [URL] = []
    @State private var dictating = false
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
                // Half a viewport of room below the last row: a sent message
                // lands mid-screen and the reply streams into the space beneath
                // it without the viewport moving.
                Color.clear.frame(height: viewportHeight * 0.5)
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
            // Only the user's own send moves the viewport: scroll to the
            // bottom, so the message sits above the half-viewport pad. Model
            // output never scrolls — the reply fills in below without the
            // view shifting.
            guard let newValue, newValue != lastJumpedToIndex else { return }
            guard case .user? = rows.last(where: { $0.id == newValue }) else { return }
            lastJumpedToIndex = newValue
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPos.scrollTo(edge: .bottom)
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

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                attachmentChips
            }
            HStack(spacing: 8) {
                #if os(macOS)
                Button(action: pickAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach files")
                #endif

                inputField
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .modifier(DictationAgentInputHighlightIfAvailable(paneID: paneID, cornerRadius: 19, dictating: $dictating))

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
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    @ViewBuilder private var inputField: some View {
        #if os(macOS)
        if dictating {
            DictationTranscriptView(fgColor: nil, fontSize: 13)
                .frame(minHeight: 17)
        } else {
            textField
        }
        #else
        textField
        #endif
    }

    private var textField: some View {
        TextField("Ask a follow-up…", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($inputFocused)
            .onSubmit { sendInput() }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.system(size: 11))
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Button(action: { attachments.removeAll { $0 == url } }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    #if os(macOS)
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Attach files to send to the agent"
        panel.begin { response in
            guard response == .OK else { return }
            addAttachments(panel.urls)
        }
    }
    #endif

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let url else { return }
                DispatchQueue.main.async { addAttachments([url]) }
            }
        }
    }

    private func addAttachments(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) {
            attachments.append(url)
        }
    }

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = attachments
        inputText = ""
        attachments = []
        session.send(text: text, attachments: files)
    }
}

private struct ScrollGeometryInfo: Equatable {
    var offsetY: CGFloat
    var viewportHeight: CGFloat
    var distanceFromBottom: CGFloat
}
