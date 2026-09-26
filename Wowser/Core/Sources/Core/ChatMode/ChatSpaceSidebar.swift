import SwiftUI
import Combine

// The chat-mode sidebar: the coordinator thread for a space, in place of the
// tab list. Favorites stay above it (see ProfilePageContent). Tabs appear as
// cards in the thread; the input at the bottom doubles as the omnibox.

struct ChatSpaceSidebar: View {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    var body: some View {
        ChatSpaceSidebarContent(session: ChatSpaceSession.session(for: profileID), windowID: windowID, profileID: profileID)
    }
}

private struct ChatSpaceSidebarContent: View {
    @ObservedObject var session: ChatSpaceSession
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    @State private var scrollPos = ScrollPosition()
    @State private var viewportHeight: CGFloat = 400
    @State private var distanceFromBottom: CGFloat = 0
    @State private var lastJumpedToID: String?
    @State private var didAppear = false
    @State private var pendingScrollRestoreY: CGFloat?
    /// Tabs whose `lastAccessed` is within the auto-collapse window; a turn
    /// that opened any of these stays expanded regardless of age.
    @State private var recentlyAccessedTabIDs: Set<ID<Tab>> = []
    private static let autoCollapseAge: TimeInterval = 60 * 60
    /// The transcript scroll view reaches this far above its slot and fades
    /// out over that distance at both ends, so clipped rows feather instead
    /// of hard-cutting against the favorites and the input.
    private let edgeFeather: CGFloat = 15

    var body: some View {
        VStack(spacing: 0) {
            transcript
            ChatOmniboxInput(session: session, windowID: windowID, profileID: profileID)
        }
        .onAppear {
            session.attach(windowID: windowID)
            lastJumpedToID = latestJumpTarget
            if let saved = session.savedScrollY {
                pendingScrollRestoreY = saved
                scrollPos.scrollTo(y: saved)
            } else if let target = latestJumpTarget {
                scrollPos.scrollTo(id: target, anchor: .bottom)
            }
            didAppear = true
        }
    }

    // MARK: - Transcript

    /// Tool-call chips are hidden here: the coordinator's work shows up as
    /// tab cards and replies, not as a log.
    private var rows: [ChatRowItem] {
        ChatRowBuilder.rows(fromThreadEntries: session.entries).filter {
            if case .toolGroup = $0 { return false }
            return true
        }
    }

    /// Consecutive tab cards are grouped so a run of cards renders as one block.
    private enum Segment: Identifiable {
        case row(ChatRowItem)
        case cards(id: String, [ChatRowItem])
        var id: String {
            switch self {
            case .row(let r): return r.id
            case .cards(let id, _): return "cards:" + id
            }
        }
    }

    private static func segments(from rows: [ChatRowItem]) -> [Segment] {
        var out: [Segment] = []
        for row in rows {
            if row.isTabCard, case .cards(let id, let items)? = out.last {
                out[out.count - 1] = .cards(id: id, items + [row])
            } else if row.isTabCard {
                out.append(.cards(id: row.id, [row]))
            } else {
                out.append(.row(row))
            }
        }
        return out
    }

    /// A user message plus everything the model produced in response (text,
    /// events, tab cards) up to the next user message. Rows before the first
    /// user message form a preamble turn with no user row.
    private struct Turn: Identifiable {
        var id: String
        var userRow: ChatRowItem?
        var userDate: Date?
        var body: [Segment]
        var tabIDs: [ID<Tab>]
    }

    private var turns: [Turn] {
        let dates = Dictionary(session.entries.map { ($0.id, $0.date) }, uniquingKeysWith: { a, _ in a })
        var out: [Turn] = []
        var current = Turn(id: "preamble", userRow: nil, userDate: nil, body: [], tabIDs: [])
        var bodyRows: [ChatRowItem] = []
        func flush() {
            current.body = Self.segments(from: bodyRows)
            if current.userRow != nil || !current.body.isEmpty { out.append(current) }
            bodyRows = []
        }
        for row in rows {
            if case .user = row {
                flush()
                current = Turn(id: row.id, userRow: row, userDate: dates[row.id], body: [], tabIDs: [])
            } else {
                bodyRows.append(row)
                if case .tabCard(_, let tabID?, _, _, _) = row { current.tabIDs.append(tabID) }
            }
        }
        flush()
        return out
    }

    private func isCollapsed(_ turn: Turn, isLast: Bool) -> Bool {
        guard turn.userRow != nil else { return false }
        if let override = session.turnCollapseOverrides[turn.id] { return override }
        // Auto-collapse: not the latest turn, older than an hour, and none of
        // its tabs were used within the hour.
        guard !isLast, let date = turn.userDate,
              Date().timeIntervalSince(date) > Self.autoCollapseAge else { return false }
        return !turn.tabIDs.contains { recentlyAccessedTabIDs.contains($0) }
    }

    private func toggleCollapse(_ turn: Turn, isLast: Bool) {
        session.turnCollapseOverrides[turn.id] = !isCollapsed(turn, isLast: isLast)
    }

    private var recentlyAccessedTabsPublisher: AnyPublisher<Set<ID<Tab>>, Never> {
        let age = Self.autoCollapseAge
        return BrowserStore.shared.uiPublisher
            .map { state in
                let cutoff = Date(timeIntervalSinceNow: -age)
                return Set(state.tabs.values.filter { $0.lastAccessed > cutoff }.map(\.id))
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private var latestJumpTarget: String? {
        rows.last(where: { $0.isJumpTarget })?.id
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty && !session.isWorking {
                    emptyState
                }
                let turns = self.turns
                ForEach(turns) { turn in
                    let isLast = turn.id == turns.last?.id
                    let collapsed = isCollapsed(turn, isLast: isLast)
                    if let userRow = turn.userRow {
                        ChatRowView(item: userRow, compact: true, windowID: windowID, openURL: openLink,
                                    turnCollapsed: collapsed, onToggleTurn: { toggleCollapse(turn, isLast: isLast) })
                            .id(userRow.id)
                            .padding(.horizontal, 12)
                    }
                    if !collapsed {
                        ForEach(turn.body) { segment in
                            switch segment {
                            case .row(let item):
                                ChatRowView(item: item, compact: true, windowID: windowID, openURL: openLink)
                                    .id(item.id)
                                    .padding(.horizontal, 12)
                            case .cards(_, let items):
                                ChatCardGroup(items: items, windowID: windowID)
                                    .id(items.first?.id ?? "")
                            }
                        }
                    }
                }
                if session.isWorking {
                    HStack(spacing: 6) {
                        AgentFruitIcon(flavor: .flavor(forKey: profileID.raw), working: true, size: 14)
                        Text(session.statusDetail ?? "Working")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stop") { session.interrupt() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .padding(.horizontal, 12)
                }
                if let errorText = session.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                }
                // Half a viewport of room below the last row: a sent message
                // lands mid-screen and the reply streams into the space beneath
                // it without the viewport moving.
                Color.clear.frame(height: viewportHeight * 0.5)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.vertical, edgeFeather, for: .scrollContent)
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: edgeFeather)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: edgeFeather)
            }
        )
        .padding(.top, -edgeFeather)
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scrollPos)
        .onReceive(recentlyAccessedTabsPublisher) { recentlyAccessedTabIDs = $0 }
        .contextMenu {
            Button("Clear Transcript") { session.clearTranscript() }
            Divider()
            Button("New Conversation") { session.clearThread() }
        }
        .onScrollGeometryChange(for: ChatScrollGeometryInfo.self) { geo in
            ChatScrollGeometryInfo(
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
                guard maxOffset > 0 else { return }
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
            // output, cards and events never scroll — the reply fills in
            // below without the view shifting.
            guard let newValue, newValue != lastJumpedToID else { return }
            guard case .user? = rows.last(where: { $0.id == newValue }) else { return }
            lastJumpedToID = newValue
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPos.scrollTo(edge: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat mode")
                .font(.system(size: 12, weight: .semibold))
            Text("Type a site, a search, or a request. Tabs show up here as cards; the agent opens pages and hands off longer jobs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// A markdown link / image clicked in the thread: open it as a tab in this
    /// space (it gets a card automatically) and show it.
    private func openLink(_ url: URL) {
        BrowserStore.shared.modify { st in
            st.openTab(url: url, activate: true, windowID: windowID)
        }
    }
}

private struct ChatScrollGeometryInfo: Equatable {
    var offsetY: CGFloat
    var viewportHeight: CGFloat
    var distanceFromBottom: CGFloat
}

/// A run of adjacent tab cards.
private struct ChatCardGroup: View {
    var items: [ChatRowItem]
    var windowID: ID<WindowState>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                ChatRowView(item: item, compact: true, windowID: windowID, openURL: { _ in })
                    .id(item.id)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
    }
}

// MARK: - Input (chat box + omnibox)

/// The chat-mode message field. It's also how the user opens tabs: as they
/// type, omnibox suggestions stack up ABOVE the field (best nearest the
/// field). Enter sends to the agent unless the typed text is clearly a site
/// (a URL/domain, a top history site, an open tab), in which case it opens
/// directly. Arrow up moves into the suggestions.
private struct ChatOmniboxInput: View {
    @ObservedObject var session: ChatSpaceSession
    let windowID: ID<WindowState>
    let profileID: ID<Profile>

    @StateObject private var searcher = Searcher()
    @State private var text = ""
    /// -1 = nothing picked (Enter sends to the agent, or opens a strong hit).
    @State private var selectedIndex = -1
    @State private var contentSize: CGSize = .zero
    @State private var focusSnap = FocusSnap()

    private var focusTarget: FocusTarget { .chatSpaceInput(profile: profileID, window: windowID) }
    private var focusDate: Date? { focusSnap.target == focusTarget ? focusSnap.date : nil }
    private var isFocused: Bool { focusSnap.target == focusTarget }

    private var results: [SearchResult] {
        // Only while there's a query — no top-sites list on an empty field.
        // Quick-nav ("jump to site") and "ask agent" rows are dropped: plain
        // Enter already sends the text to the agent, and a guessed site is
        // a worse default than a search. Capped at 3 so the stack above the
        // field stays short.
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return Array(searcher.results.filter { r in
            switch r.item.content {
            case .imFeelingLucky, .askAgent: return false
            default: return true
            }
        }.prefix(3))
    }

    /// A result confident enough that plain Enter should open it rather than
    /// send the text to the agent.
    private var strongIndex: Int? {
        for (i, r) in results.enumerated() {
            switch r.item.content {
            case .urlYouTyped: return i
            case .tab where r.matchQuality == .prefixMatchURL: return i
            case .historyItem where r.matchQuality == .prefixMatchURL && r.score >= 30: return i
            default: continue
            }
        }
        return nil
    }

    private var effectiveIndex: Int { selectedIndex >= 0 ? selectedIndex : (strongIndex ?? -1) }

    var body: some View {
        VStack(spacing: 0) {
            if isFocused, !results.isEmpty {
                suggestions
            }
            field
        }
        .onReceiveFocusSnap(windowID: windowID) { focusSnap = $0 }
        .onReceive(profileDataStoreID) { searcher.datastoreProfileID = $0 }
        .onAppearOrChange(of: windowID) { searcher.windowID = $0 }
        .onChange(of: text) { _, newValue in
            searcher.query = newValue
            selectedIndex = -1
        }
    }

    private var suggestions: some View {
        // Bottom-up: results[0] sits right above the field.
        VStack(spacing: 0) {
            if results.count > 1 {
                Color.primary.opacity(0.1)
                    .frame(height: 1)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
            ForEach(Array(results.enumerated().reversed()), id: \.element.id) { index, result in
                ChatSuggestionRow(
                    result: result,
                    isSelected: index == effectiveIndex,
                    strong: index == strongIndex && selectedIndex < 0,
                    onSelect: { select(result) }
                )
            }
        }
        .padding(4)
        .padding(.bottom, 2)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            InputTextField(
                text: $text,
                options: InputTextFieldOptions(
                    placeholder: "Message, site, or search",
                    font: .systemFont(ofSize: 12.5),
                    color: UINSColor.textColor,
                    insets: CGSize(width: 8, height: 7),
                    wantsUpDownArrowEvents: true,
                    selectAllOnFocus: false,
                    lineLimit: 5,
                    disableFindReplace: true
                ),
                focusDate: focusDate,
                focusTarget: focusTarget,
                onEvent: handleEvent,
                contentSize: $contentSize
            )
            .frame(height: max(30, min(contentSize.height, 110)))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocused ? 0.18 : 0.08), lineWidth: 1)
            )
            .onTapGesture { focus() }

            if session.isWorking {
                Button(action: { session.interrupt() }) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Stop")
                .padding(.bottom, 5)
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submit) {
                    Image(systemName: effectiveIndex >= 0 ? "arrow.right.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(effectiveIndex >= 0 ? "Open" : "Send")
                .padding(.bottom, 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var profileDataStoreID: AnyPublisher<UUID?, Never> {
        let pid = profileID
        return BrowserStore.shared.uiPublisher
            .map { $0.profiles[pid]?.dataStoreUUID }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private func handleEvent(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter):
            submit()
        case .key(.upArrow):
            guard !results.isEmpty else { return }
            selectedIndex = min(results.count - 1, selectedIndex + 1)
        case .key(.downArrow):
            selectedIndex = max(-1, selectedIndex - 1)
        case .key(.escape):
            if !text.isEmpty {
                text = ""
            } else {
                blur()
            }
        case .focus:
            BrowserStore.shared.modify { st in st.didFocus(target: focusTarget) }
        case .blur:
            BrowserStore.shared.modify { st in st.didLoseFocus(target: focusTarget) }
        case .didPasteURL(let url):
            text = url.absoluteString
        default:
            break
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let idx = effectiveIndex
        if idx >= 0, let result = results.get(idx) {
            select(result)
        } else {
            text = ""
            session.send(text: trimmed)
        }
    }

    private func select(_ result: SearchResult) {
        text = ""
        selectedIndex = -1
        // Open in a NEW tab: in chat mode the field is the new-tab entry
        // point, never an edit of the current page's URL.
        BrowserStore.shared.select(result: result, windowID: windowID, forceNewTab: true)
        // Whatever the user opened lands at the bottom of the thread. A fresh
        // tab already got a card from tab observation (addCard dedupes that);
        // this covers re-activating an existing tab or loading into a blank
        // current tab, where no new tab appears.
        let windowID = windowID
        DispatchQueue.main.async {
            guard let tabID = BrowserStore.shared.model.windows[windowID]?.currentTab else { return }
            session.addCard(tabID: tabID, force: true)
        }
    }

    private func focus() {
        BrowserStore.shared.modify { st in st.didFocus(target: focusTarget) }
    }

    private func blur() {
        BrowserStore.shared.modify { st in st.didLoseFocus(target: focusTarget) }
    }
}

private struct ChatSuggestionRow: View {
    let result: SearchResult
    let isSelected: Bool
    /// Highlighted because Enter would open it (nothing explicitly picked).
    let strong: Bool
    let onSelect: () -> Void

    var body: some View {
        let title = result.item.title
        let subtitle = result.item.subtitle
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SearchIcon(item: result.item, size: 16, selected: isSelected)
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .layoutPriority(2)
                }
                if let subtitle, !subtitle.isEmpty, title.isEmpty || !strong {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .opacity(0.5)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
                if strong {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .lineLimit(1)
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected, desaturatedHighlight: strong && isSelected))
    }
}
