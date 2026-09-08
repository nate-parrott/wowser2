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

    var body: some View {
        VStack(spacing: 0) {
            header
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            Spacer()
            Button(action: showRecentTabs) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(both: 24)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Recent tabs")

            Button(action: { session.clearThread() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(both: 24)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Clear thread")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func showRecentTabs() {
        NotificationCenter.default.post(name: .beginTabStackBrowse, object: nil, userInfo: [tabStackCycleWindowIDKey: windowID])
    }

    // MARK: - Transcript

    private var rows: [ChatRowItem] {
        ChatRowBuilder.rows(fromThreadEntries: session.entries)
    }

    /// Consecutive tab cards are grouped so a run of cards can be closed
    /// together from one hover button.
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

    private var segments: [Segment] {
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

    private var latestJumpTarget: String? {
        rows.last(where: { $0.isJumpTarget })?.id
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty && !session.isWorking {
                    emptyState
                }
                ForEach(segments) { segment in
                    switch segment {
                    case .row(let item):
                        ChatRowView(item: item, compact: true, windowID: windowID, openURL: openLink)
                            .id(item.id)
                            .padding(.horizontal, 8)
                    case .cards(_, let items):
                        ChatCardGroup(items: items, windowID: windowID)
                            .id(items.first?.id ?? "")
                    }
                }
                if session.isWorking {
                    HStack(spacing: 6) {
                        LoadingIndicator(progress: nil)
                            .frame(width: 14, height: 14)
                        Text(session.statusDetail ?? "Working…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stop") { session.interrupt() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .padding(.horizontal, 8)
                }
                if let errorText = session.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                }
                Color.clear.frame(height: 12)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scrollPos)
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
        .onChange(of: rows.count) { _, _ in
            // New rows (cards, tool chips, streamed text): follow the bottom
            // unless the user scrolled up to read.
            guard didAppear, distanceFromBottom < viewportHeight * 1.5 else { return }
            if let last = rows.last {
                lastJumpedToID = last.id
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollPos.scrollTo(id: last.id, anchor: .bottom)
                }
            }
        }
        .onChange(of: latestJumpTarget) { _, newValue in
            guard let newValue, newValue != lastJumpedToID else { return }
            let isOwnSend: Bool = { if case .user? = rows.last(where: { $0.id == newValue }) { return true }; return false }()
            if isOwnSend || distanceFromBottom < viewportHeight * 1.5 {
                lastJumpedToID = newValue
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollPos.scrollTo(id: newValue, anchor: .bottom)
                }
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

/// A run of adjacent tab cards. Hovering reveals a close-all button so the
/// user can sweep a batch of pages the agent opened.
private struct ChatCardGroup: View {
    var items: [ChatRowItem]
    var windowID: ID<WindowState>
    @State private var hovered = false

    private var openTabIDs: [ID<Tab>] {
        let state = BrowserStore.shared.model
        return items.compactMap { item -> ID<Tab>? in
            if case .tabCard(_, let tabID, _, _, _) = item, let tabID, state.tabs[tabID] != nil { return tabID }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                ChatRowView(item: item, compact: true, windowID: windowID, openURL: { _ in })
                    .id(item.id)
            }
        }
        .padding(.horizontal, 2)
        .overlay(alignment: .topTrailing) {
            if hovered, items.count > 1, openTabIDs.count > 1 {
                Button(action: closeAll) {
                    Image(systemName: "xmark")
                        .help("Close these \(openTabIDs.count) tabs")
                }
                .buttonStyle(TabAccessoryButtonStyle())
                .offset(x: -6, y: -18)
            }
        }
        .padding(.top, items.count > 1 ? 6 : 0)
        .onHover { hovered = $0 }
    }

    private func closeAll() {
        for tabID in openTabIDs {
            closeTab(tabID: tabID)
        }
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
        text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : searcher.results
    }

    /// A result confident enough that plain Enter should open it rather than
    /// send the text to the agent.
    private var strongIndex: Int? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = query.split(separator: " ").count
        for (i, r) in results.enumerated() {
            switch r.item.content {
            case .urlYouTyped: return i
            case .tab where r.matchQuality == .prefixMatchURL: return i
            case .historyItem where r.matchQuality == .prefixMatchURL && r.score >= 30: return i
            case .imFeelingLucky where words <= 2: return i
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
        switch result.item.content {
        case .askAgent(let query, _):
            session.send(text: query)
        default:
            // Open in a NEW tab: in chat mode the field is the new-tab entry
            // point, never an edit of the current page's URL.
            BrowserStore.shared.select(result: result, windowID: windowID, forceNewTab: true)
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
