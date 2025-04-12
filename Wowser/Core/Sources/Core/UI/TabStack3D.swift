import SwiftUI

struct TabStack3D: View {
    var snapshot: WindowSnapshot
    var topbarVisible: Bool
    
    @State private var cards = [Card]()
    @State private var size: CGSize?
    @State private var animCount = 0
    @State private var swipeGestureOffsetAnimatable: Int?
        
    var body: some View {
        let swiping = swipeGestureOffsetAnimatable != nil
        ZStack {
            ForEach(cards) { card in
                let idx = cards.firstIndex(of: card) ?? 0
                
                render(card: card)
                    .clipped()
                    .rotation3DEffect(Angle(degrees: swipeGestureOffsetAnimatable != nil ? -10 : 0), axis: (x: 1, y: 0, z: 0), anchor: .top, anchorZ: 0, perspective: 1)
                    .zIndex(Double(idx))
                    .scaleEffect(swiping ? 0.9 : 1)
                    .offset(y: yOffset(forIndex: idx))
                    .transition(cardTransition(index: idx))
            }
        }
        .measureSize({ self.size = $0 })
        .animation(.spring(), value: animCount)
//        .animation(.spring(), value: snapshot.swipeGestureOffset)
//        .animation(.spring(), value: cards.map(\.id))
        .onChange(of: snapshot, initial: true) { oldValue, newValue in
            swipeGestureOffsetAnimatable = newValue.swipeGestureOffset
            
            if oldValue.tabId != newValue.tabId || cards.count == 0 {
                // Ensure cards contains current tab and is marked live
                for i in 0..<cards.count {
                    cards[i].isLive = cards[i].tabId == newValue.tabId
                }
                let hasLiveTab = cards.contains(where: { $0.isLive })
                if !hasLiveTab {
                    cards.append(Card(id: UUID().uuidString, tabId: newValue.tabId, isLive: true))
                }
            }
            
            let isGesturing = newValue.swipeGestureOffset != nil
            let wasGesturing = oldValue.swipeGestureOffset != nil
            if isGesturing != wasGesturing {
                if isGesturing {
                    // Gesture began
                    self.cards = newValue.recentTabIds.reversed().map({ tabId in
                        Card(id: UUID().uuidString, tabId: tabId, isLive: false)
                    }) + self.cards
                }
            }
            
            if oldValue.swipeGestureOffset != newValue.swipeGestureOffset {
                animCount += 1
            }
            
            if newValue.swipeGestureOffset == nil {
                // No gesture; remove unused
                self.cards = self.cards.filter({ $0.isLive })
            }
            
            // may happen if cur tab is nil?
            if self.cards.count == 0 {
                self.cards.append(Card(id: UUID().uuidString, tabId: newValue.tabId, isLive: true))
                print("[TabStack3D] OOPS: no cards in stack so creating one...")
            }
        }
    }
    
//    var cardTransition: AnyTransition {
//        .asymmetric(insertion: , removal: .offset(y: (size?.height ?? 0) + 100))
//    }
    
    func cardTransition(index: Int) -> AnyTransition {
        .opacity
//        let height = size?.height ?? 0
//        let insertion: AnyTransition = .offset(y: -200).combined(with: .opacity)
//        let removal: AnyTransition
//        let focusedIdx = max(0, cards.count - 1 - (swipeGestureOffsetAnimatable ?? 0))
//        if index > focusedIdx {
//            removal = .opacity // .offset(y: height + 100)
//        } else {
//            removal = .offset(y: -height / 2 - 100)
//        }
//        return .asymmetric(insertion: insertion, removal: removal)
    }
    
    func yOffset(forIndex index: Int) -> CGFloat {
        let height = size?.height ?? 0
        let focusedIdx = max(0, cards.count - 1 - (swipeGestureOffsetAnimatable ?? 0))
        if swipeGestureOffsetAnimatable == nil {
            return index > focusedIdx ? height + 50 : -height - 50
        }
        if index > focusedIdx {
            if index > focusedIdx + 1 {
                return height + 100
            }
            return height - 100
        }
        return Double(index - focusedIdx) * 20
    }
    
    struct Card: Identifiable, Equatable {
        var id: String
        var tabId: ID<Tab>?
        var isLive: Bool
    }
    
    @ViewBuilder func render(card: Card) -> some View {
        ZStack {
            Color("Background", bundle: .module)
            if card.isLive {
                TabContentView(snapshot: snapshot, topbarVisible: topbarVisible)
            } else if let tabId = card.tabId {
                WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabId]?.panes.first?.id }) { id in
                    FakePaneView(webContentId: id, focused: true, singlePane: true, topbarVisible: topbarVisible, toolbarColorScheme: nil)
                }
            }
//            else {
//                Color("Background", bundle: .module)
//            }
        }
        .compositingGroup()
    }
}

struct TabContentView: View {
    var snapshot: WindowSnapshot
    var topbarVisible: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.panes) { pane in
                PaneView(snapshot: pane, singlePane: snapshot.panes.count == 1, topbarVisible: topbarVisible || pane.emptyPage, toolbarColorScheme: pane.colorScheme)
            }
        }
    }
}

//struct TabStack3D: View {
//    var snapshot: WindowSnapshot.PaneSnapshot
//    var singlePane: Bool
//    var topbarVisible: Bool
//    var toolbarColorScheme: ContentColorScheme?
//    
//    @Environment(\.windowID) private var windowID
//
//    var body: some View {
//        PaneView(snapshot: snapshot, singlePane: singlePane, topbarVisible: topbarVisible, toolbarColorScheme: toolbarColorScheme)
//    }
//    
//    @ViewBuilder func render(webContentId: ID<WebContent>, real: Bool) -> some View {
//        if real {
//            PaneView(snapshot: snapshot, singlePane: singlePane, topbarVisible: topbarVisible, toolbarColorScheme: toolbarColorScheme)
//        } else {
//            FakePaneView(snapshot: snapshot, singlePane: singlePane, topbarVisible: topbarVisible, toolbarColorScheme: toolbarColorScheme)
//        }
//    }
//}

//private class TabStack3DModel: ObservableObject {
//    @Published
//    @Published private(set) var currentWebContentId: ID<WebContent>?
//    @Published private(set) var orderedWebContents = Set<ID<WebContent>>()
//}

//private struct TabStack3DModel: Equatable {
//    private(set) var gestureOffset: Int?
//    private(set) var currentWebContentId: ID<WebContent>?
//    private(set) var orderedWebContents = Set<ID<WebContent>>()
//}
//
//private struct TabStackInputSnapshot: Equatable {
//    var gestureOffset: Int?
//    var currentWebContentId: ID<WebContent>?
//    var previousWebContent: [ID<WebContent>] // in most-recently-used order, only set if gesture is active
//}
//
//private extension BrowserState {
//    func tabStackInputSnapshot(forWindowID id: ID<WindowState>?, curWebContentId: ID<WebContent>?) -> TabStackInputSnapshot {
//        guard let id, let win = windows[id] else {
//            return .init(previousWebContent: [])
//        }
//        // TODO: be split-view aware
//        return .init(
//            gestureOffset: win.swipeGestureOffset,
//            currentWebContentId: curWebContentId,
//            previousWebContent: <#T##[ID<WebContent>]#>
//        )
//    }
//}
