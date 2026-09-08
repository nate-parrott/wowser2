import SwiftUI

extension Notification.Name {
    /// Posted to step the TabStack3D one tab back (keyboard cycle, e.g. cmd+E).
    /// userInfo["windowID"] = ID<WindowState>
    public static let beginTabStackCycle = Notification.Name("beginTabStackCycle")
    /// Posted to commit/end the keyboard tab-stack cycle (e.g. cmd released).
    /// userInfo["windowID"] = ID<WindowState>
    public static let endTabStackCycle = Notification.Name("endTabStackCycle")
    /// Posted to open the 3D stack as a click/scroll-driven switcher (no
    /// gesture or held key). Dismissed by clicking a card, Escape, or
    /// clicking outside. userInfo["windowID"] = ID<WindowState>
    public static let beginTabStackBrowse = Notification.Name("beginTabStackBrowse")
}

public let tabStackCycleWindowIDKey = "windowID"

struct TabStack3D: View {
    var snapshot: WindowSnapshot
    var topbarVisible: Bool

    @StateObject private var model = TabStack3DModel()
    @State private var size: CGSize?
    @Environment(\.windowID) private var windowID

    var body: some View {
        let (cards, selectedIdx) = model.cardsAndSelectedIndex
        ZStack {
            ForEach(cards) { card in
                let idx = cards.firstIndex(of: card) ?? 0

                render(card: card)
                    .overlay {
                        // In browse mode every card is a button: click to switch.
                        if model.isBrowsing {
                            Color.black.opacity(0.0001)
                                .contentShape(Rectangle())
                                .onTapGesture { commitBrowse(selecting: card) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: model.isActive3D ? 8 : 0))
                    .shadow(color: Color.black.opacity(model.isActive3D ? 0.07 : 0), radius: 4, x: 0, y: 0)
                    .rotation3DEffect(Angle(degrees: model.isActive3D ? -15 : 0), axis: (x: 1, y: 0, z: 0), anchor: .top, anchorZ: 0, perspective: 1)
                    .zIndex(Double(idx))
                    .scaleEffect(model.isActive3D ? 0.9 : 1)
                    .offset(y: yOffset(forIndexOffset: idx - selectedIdx))
//                    .transition(cardTransition(beforeActiveCard: idx < selectedIdx))
            }
        }
        .measureSize({ self.size = $0 })
        #if os(macOS)
        .overlay {
            if model.isBrowsing, let windowID {
                TabStackBrowseInputCatcher(
                    onScroll: { steps in model.browseScroll(by: steps, windowID: windowID) },
                    onEscape: { model.swipeGestureOffsetChanged(offset: nil, windowID: windowID) }
                )
                .allowsHitTesting(false)
            }
        }
        #endif
        .animation(.spring(), value: model.animCount)
//        .animation(.spring(), value: snapshot.swipeGestureOffset)
//        .animation(.spring(), value: cards.map(\.id))
        .onChange(of: snapshot, initial: true) { oldValue, newValue in
            guard let windowID else { return }
            if oldValue.swipeGestureOffset != newValue.swipeGestureOffset {
                model.swipeGestureOffsetChanged(offset: newValue.swipeGestureOffset, windowID: windowID)
            }
            if oldValue.tabId != newValue.tabId {
                model.swipeGestureActiveTabChanged(tabId: newValue.tabId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginTabStackCycle)) { note in
            guard let windowID, note.userInfo?[tabStackCycleWindowIDKey] as? ID<WindowState> == windowID else { return }
            model.swipeGestureOffsetChanged(offset: model.keyboardCycleNextOffset, windowID: windowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginTabStackBrowse)) { note in
            guard let windowID, note.userInfo?[tabStackCycleWindowIDKey] as? ID<WindowState> == windowID else { return }
            model.beginBrowse(windowID: windowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .endTabStackCycle)) { note in
            guard let windowID, note.userInfo?[tabStackCycleWindowIDKey] as? ID<WindowState> == windowID else { return }
            // Commit the visually-selected tab before dismissing the stack.
            let (cards, selectedIdx) = model.cardsAndSelectedIndex
            if let card = cards.get(selectedIdx), let tabId = card.tabId {
                BrowserStore.shared.modify { state in
                    state.activate(tabId: tabId, in: windowID)
                }
            }
            model.swipeGestureOffsetChanged(offset: nil, windowID: windowID)
        }
    }
    
    private func commitBrowse(selecting card: TabStack3DModel.Card) {
        guard let windowID else { return }
        if let tabId = card.tabId {
            BrowserStore.shared.modify { state in
                state.activate(tabId: tabId, in: windowID)
                state.unghostTab(id: tabId)
            }
        }
        model.swipeGestureOffsetChanged(offset: nil, windowID: windowID)
    }

    func yOffset(forIndexOffset offset: Int) -> CGFloat {
        let height = size?.height ?? 0
        let baseOffset: CGFloat = min(100, height * 0.2)
        
        if model.isActive3D {
            if offset == 0 {
                return baseOffset
            } else if offset < 0 {
                return -40 * Double(abs(offset)) + baseOffset
            } else {
                return height - 100 + 50 * Double(offset - 1)
            }
//            return Double(index - focusedIdx) * 20
        } else {
            // Inactive
            if offset == 0 {
                return 0
            } else if offset < 0 {
                return -200 // -height - 50
            } else {
                return height + 50
            }
        }
    }
    
    @ViewBuilder private func render(card: TabStack3DModel.Card) -> some View {
        ZStack {
//            Color("Background", bundle: .module)
//                .opacity(0.5)
            if card.isLive {
                TabContentView(snapshot: snapshot, topbarVisible: topbarVisible)
                    .transition(.identity)
            }
            
            if !card.isLive, let tabId = card.tabId {
                WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabId]?.panes.first.map(TabStackCardSnapshot.init(pane:)) }) { pane in
                    if let pane {
                        FakePaneView(webContentId: pane.webContentId, nativeKey: pane.nativeKey, focused: true, singlePane: true, topbarVisible: topbarVisible, toolbarColorScheme: pane.colorScheme, topbarLocked: snapshot.sidebarLocked)
                            .overlay {
                                TabStackCardOverlay(tabId: tabId)
                                    .transition(.opacity)
                            }
                    }
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.niceDefault(duration: 0.2).delay(0.2))))
            }
//            else {
//                Color("Background", bundle: .module)
//            }
        }
        .compositingGroup()
    }
}

private struct TabStackCardSnapshot: Equatable {
    var webContentId: ID<WebContent>
    var nativeKey: NativePageKey?
    var colorScheme: ContentColorScheme?

    init(pane: Pane) {
        webContentId = pane.id
        nativeKey = pane.info.url.flatMap(NativePageKey.init(url:))
        colorScheme = pane.info.colorScheme
    }
}

private class TabStack3DModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        var id: String
        var tabId: ID<Tab>?
        var isLive: Bool
        
        static var emptyCard: Card {
            Card(id: UUID().uuidString, isLive: true)
        }
    }
    enum State: Equatable {
        case normal(Card)
        case pre3d(gestureId: UUID, orderedCards: [Card], swipeOffset: Int) // looks normal but rendering cards behind for pre-transition. orderedCards[-1] is visible.
        case active3d(gestureId: UUID, orderedCards: [Card], swipeOffset: Int) // orderedCards[-1-swipeOffset] is visible
        case post3d(gestureId: UUID, orderedCards: [Card], swipeOffset: Int)
    }
    @Published private(set) var state: State = .normal(.emptyCard)
    @Published private(set) var animCount = 0
    /// Browse mode: the stack was opened from a button rather than a gesture,
    /// so it stays up until a card is clicked, Escape, or a click outside.
    @Published private(set) var isBrowsing = false
    private var browseScrollAccumulator: CGFloat = 0

    /// Open the stack for browsing: current tab selected, more cards than a
    /// gesture shows, and no auto-dismiss.
    func beginBrowse(windowID: ID<WindowState>) {
        guard case .normal = state else { return }
        isBrowsing = true
        browseScrollAccumulator = 0
        swipeGestureOffsetChanged(offset: 0, windowID: windowID, maxCards: 12)
    }

    /// Scroll-wheel steps while browsing: positive = further back in history.
    func browseScroll(by delta: CGFloat, windowID: ID<WindowState>) {
        guard isBrowsing else { return }
        browseScrollAccumulator += delta
        let stepSize: CGFloat = 40
        while abs(browseScrollAccumulator) >= stepSize {
            let dir = browseScrollAccumulator > 0 ? 1 : -1
            browseScrollAccumulator -= CGFloat(dir) * stepSize
            switch state {
            case .active3d(_, let cards, let offset), .pre3d(_, let cards, let offset), .post3d(_, let cards, let offset):
                let next = max(0, min(cards.count - 1, offset + dir))
                if next != offset { swipeGestureOffsetChanged(offset: next, windowID: windowID) }
            case .normal: return
            }
        }
    }
    
    func swipeGestureOffsetChanged(offset: Int?, windowID: ID<WindowState>, maxCards: Int = 5) {
        if let offset {
            // Gesture should be active
            switch state {
            case .normal(let card):
                // Transition to pre3d, then active 3d
                let newCards = BrowserStore.shared.model.tabsInRecencyOrder(inWindow: windowID, max: maxCards)
                    .map { tabId in
                        if card.tabId == tabId {
                            return card
                        } else {
                            return Card(id: UUID().uuidString, tabId: tabId, isLive: false)
                        }
                    }.reversed().asArray
                let gestureId = UUID()
                self.state = .pre3d(gestureId: gestureId, orderedCards: newCards, swipeOffset: offset)
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    self.transitionToActive3dFromPre3dState(ifGestureIdStill: gestureId)
                }
            case .pre3d(let gestureId, let orderedCards, _):
                // Just update the offset
                self.state = .pre3d(gestureId: gestureId, orderedCards: orderedCards, swipeOffset: offset)
            case .active3d(let gestureId, let orderedCards, _):
                // Just update the offset
                self.state = .active3d(gestureId: gestureId, orderedCards: orderedCards, swipeOffset: offset)
                animCount += 1
            case .post3d(let gestureId, let orderedCards, _):
                // Just update the offset
                self.state = .post3d(gestureId: gestureId, orderedCards: orderedCards, swipeOffset: offset)
            }
        } else {
            // Gesture should end
            isBrowsing = false
            switch state {
            case .normal(_): () // Already in correct state
            case .pre3d(_, let orderedCards, _):
                // Can end immediately
                state = .normal(orderedCards.last ?? .emptyCard)
            case .active3d(let gestureId, let orderedCards, let swipeOffset):
                // End
                self.state = .post3d(gestureId: gestureId, orderedCards: orderedCards, swipeOffset: swipeOffset)
                self.animCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.returnToNormalFromPost3dState(ifGestureIdStill: gestureId)
                }
            case .post3d(let gestureId, _, _):
                returnToNormalFromPost3dState(ifGestureIdStill: gestureId)
            }
        }
    }
    
    var cardsAndSelectedIndex: ([Card], Int) {
        switch state {
        case .normal(let card):
            return ([card], 0)
        case .pre3d(_, let orderedCards, _):
            // We store the swipe offset but do NOT render it yet
            return (orderedCards, orderedCards.count - 1) // orderedCards.count - 1 - swipeOffset)
        case .active3d(_, let orderedCards, let swipeOffset):
            return (orderedCards, orderedCards.count - 1 - swipeOffset)
        case .post3d(_, let orderedCards, let swipeOffset):
            return (orderedCards, orderedCards.count - 1 - swipeOffset)
        }
    }
    
    var isActive3D: Bool {
        if case .active3d = state {
            return true
        }
        return false
    }

    /// Offset to use for the next keyboard cycle step. Starts at 1 (first
    /// non-current tab); each subsequent press increments.
    var keyboardCycleNextOffset: Int {
        switch state {
        case .normal:
            return 1
        case .pre3d(_, _, let offset), .active3d(_, _, let offset), .post3d(_, _, let offset):
            return offset + 1
        }
    }
    
    func swipeGestureActiveTabChanged(tabId: ID<Tab>?) {
        switch state {
        case .normal(let card):
            if card.tabId == tabId {
                // no change
            } else {
                state = .normal(Card(id: UUID().uuidString, tabId: tabId, isLive: true))
            }
        case .pre3d(let gestureId, let orderedCards, let swipeOffset):
            state = .pre3d(gestureId: gestureId, orderedCards: updateCardList(orderedCards, toReflectActiveTabId: tabId), swipeOffset: swipeOffset)
        case .active3d(let gestureId, let orderedCards, let swipeOffset):
            state = .active3d(gestureId: gestureId, orderedCards: updateCardList(orderedCards, toReflectActiveTabId: tabId), swipeOffset: swipeOffset)
            animCount += 1
        case .post3d(let gestureId, let orderedCards, let swipeOffset):
            state = .post3d(gestureId: gestureId, orderedCards: updateCardList(orderedCards, toReflectActiveTabId: tabId), swipeOffset: swipeOffset)
            animCount += 1
        }
    }
    
    private func updateCardList(_ cards: [Card], toReflectActiveTabId selectedTabId: ID<Tab>?) -> [Card] {
        var cards = cards.map { card in
            var c = card
            c.isLive = selectedTabId == card.tabId
            return c
        }
        if !cards.contains(where: { $0.isLive }) {
            cards.append(Card(id: UUID().uuidString, tabId: selectedTabId, isLive: true))
        }
        return cards
    }
    
    private func transitionToActive3dFromPre3dState(ifGestureIdStill id: UUID) {
        if case .pre3d(let gestureId, let orderedCards, let swipeOffset) = state, gestureId == id {
            self.state = .active3d(gestureId: gestureId, orderedCards: orderedCards, swipeOffset: swipeOffset)
            self.animCount += 1
        }
    }
    
    private func returnToNormalFromPost3dState(ifGestureIdStill id: UUID) {
        if case .post3d(let gestureId, let orderedCards, let swipeOffset) = self.state, gestureId == id {
            if let selectedCard = orderedCards.get(orderedCards.count - 1 - swipeOffset) {
                state = .normal(selectedCard)
            } else {
                state = .normal(.emptyCard)
            }
        }
    }
}

struct TabContentView: View {
    var snapshot: WindowSnapshot
    var topbarVisible: Bool

    var body: some View {
        if snapshot.panes.count <= 1 {
            HStack(spacing: 0) {
                ForEach(snapshot.panes) { pane in
                    PaneView(snapshot: pane, singlePane: true, topbarVisible: topbarVisible || pane.emptyPage, toolbarColorScheme: pane.colorScheme)
                        .dropToCreateSplitViewTarget(paneId: pane.webContentId)
                }
            }
        } else {
            GeometryReader { geo in
                let totalWeight = max(snapshot.panes.map(\.weight).reduce(0, +), 0.0001)
                let widths = snapshot.panes.map { geo.size.width * ($0.weight / totalWeight) }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(snapshot.panes.enumerated()), id: \.element.id) { idx, pane in
                            PaneView(snapshot: pane, singlePane: false, topbarVisible: topbarVisible || pane.emptyPage, toolbarColorScheme: pane.colorScheme)
                                .frame(width: widths[idx])
                                .dropToCreateSplitViewTarget(paneId: pane.webContentId)
                        }
                    }
                    if let tabId = snapshot.tabId {
                        ForEach(0..<max(snapshot.panes.count - 1, 0), id: \.self) { idx in
                            let seamX = widths.prefix(idx + 1).reduce(0, +)
                            PaneSplitDivider(
                                tabId: tabId,
                                leftPaneIdx: idx,
                                totalWidth: geo.size.width
                            )
                            .frame(height: geo.size.height)
                            .offset(x: seamX - 4) // 4px hit area centered on seam (frame is 8px wide)
                        }
                    }
                }
            }
        }
    }
}

private struct PaneSplitDivider: View {
    let tabId: ID<Tab>
    let leftPaneIdx: Int
    let totalWidth: CGFloat

    @State private var dragStartLeftWeight: Double?
    @State private var dragStartRightWeight: Double?
    @State private var dragStartTotalWeight: Double?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.1)
                .frame(width: 1)
                .allowsHitTesting(false)
            Color.black.opacity(0.0001) // non-clear so it always receives hits, even over WKWebView
                .frame(width: 8)
                .contentShape(Rectangle())
                #if os(macOS)
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                #endif
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startLeft: Double
                            let startRight: Double
                            let startTotal: Double
                            if let l = dragStartLeftWeight, let r = dragStartRightWeight, let t = dragStartTotalWeight {
                                startLeft = l
                                startRight = r
                                startTotal = t
                            } else {
                                let state = BrowserStore.shared.model
                                guard let tab = state.tabs[tabId],
                                      let left = tab.panes[leftPaneIdx],
                                      let right = tab.panes[leftPaneIdx + 1] else { return }
                                startLeft = left.weight ?? 1.0
                                startRight = right.weight ?? 1.0
                                let total = tab.panes.elements.map { $0.weight ?? 1.0 }.reduce(0, +)
                                startTotal = max(total, 0.0001)
                                self.dragStartLeftWeight = startLeft
                                self.dragStartRightWeight = startRight
                                self.dragStartTotalWeight = startTotal
                            }

                            let pairWeight = startLeft + startRight
                            let unitsPerPx = startTotal / max(totalWidth, 1)
                            let deltaWeight = Double(value.translation.width) * unitsPerPx
                            let minWeight = pairWeight * 0.05
                            var newLeft = startLeft + deltaWeight
                            newLeft = min(max(newLeft, minWeight), pairWeight - minWeight)
                            let newRight = pairWeight - newLeft

                            BrowserStore.shared.modify { state in
                                state.setPaneWeights(tabId: tabId, leftPaneIdx: leftPaneIdx, leftWeight: newLeft, rightWeight: newRight)
                            }
                        }
                        .onEnded { _ in
                            dragStartLeftWeight = nil
                            dragStartRightWeight = nil
                            dragStartTotalWeight = nil
                        }
                )
        }
        .frame(width: 8)
    }
}

private struct TabStackCardOverlay: View {
    var tabId: ID<Tab>

    var body: some View {
        // Tab-level appearance, so the user's custom title and icon show up here
        // just like they do in the sidebar.
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabId]?.appearance() }) { appearance in
            if let appearance {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                    
                    HStack(spacing: 8) {
                        TabIconView(icon: appearance.icon)
                        Text(appearance.title)
                            .font(.system(size: 12, weight: .medium))
                            .italic(appearance.isCustomTitle)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
                }
            }
        }
    }
}


#if os(macOS)
import AppKit

/// While the stack is open for browsing, this catches scroll-wheel events
/// and Escape anywhere in the window, so the user can flip through cards
/// without a trackpad gesture. Installed as a local event monitor; the view
/// itself never intercepts clicks (cards handle those).
private struct TabStackBrowseInputCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(onScroll: onScroll, onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onScroll: ((CGFloat) -> Void)?
        var onEscape: (() -> Void)?
        private var monitors: [Any] = []

        func install(onScroll: @escaping (CGFloat) -> Void, onEscape: @escaping () -> Void) {
            self.onScroll = onScroll
            self.onEscape = onEscape
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Trackpad deltas are in points; wheel clicks are coarse.
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                self?.onScroll?(-delta)
                return nil
            } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.onEscape?(); return nil }
                return event
            } as Any)
        }

        func uninstall() {
            for m in monitors { NSEvent.removeMonitor(m) }
            monitors.removeAll()
        }

        deinit { uninstall() }
    }
}
#endif
