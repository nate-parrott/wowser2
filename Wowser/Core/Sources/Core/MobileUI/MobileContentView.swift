import Combine
import SwiftUI

public struct MobileContentView: View {
    public var windowID: ID<WindowState>
        
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { MobileContentSnapshot(state: $0, windowID: windowID) }) { snapshot in
            _MobileContentView(snapshot: snapshot)
                .environment(\.profileID, snapshot.profileID)
        }
        .environment(\.windowID, windowID)
    }
}

private struct _MobileContentView: View {
    var snapshot: MobileContentSnapshot
    @Environment(\.profileID) private var profileID
    @Environment(\.windowID) private var windowID
    @StateObject private var orbUnitX = MomentumValue(initialValue: 0, scale: 300, params: .interactiveGrab)
    @StateObject private var orbUnitY = MomentumValue(initialValue: 0, scale: 300, params: .interactiveGrab)
    @State private var size = CGSize(width: 100, height: 100)
    @StateObject private var topSitesFetcher = TopSitesFetcher()
    @State private var settingsPresented = false
    
    var body: some View {
        ZStack {
            webContent

            SearchOrb(xPos: orbUnitX, yPos: orbUnitY)
                .edgesIgnoringSafeArea(.all)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            
            MobileSidebarOverlay(viewSize: size, orbYPos: orbUnitY)
                .edgesIgnoringSafeArea(.all)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            
            searchOverlay
//            if snapshot.searchActive {
//                 
//            }
        }
        .background {
            Color.clear
                .measureSize({ self.size = $0 })
                .edgesIgnoringSafeArea(.all)
        }
        .background {
            Group {
                snapshot.windowBgColor?.color
            }
            .ignoresSafeArea()
        }
        .onAppear {
            setupOrbPos()
        }
        .onReceive(profileDataStoreID, perform: { id in
            topSitesFetcher.profileDataStoreID = id
        })
        #if os(iOS)
        .modifier(DeviceShakeViewModifier(action: { settingsPresented = true }))
        #endif
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
        }
    }
    
    var profileDataStoreID: AnyPublisher<UUID?, Never> {
        guard let profileID else {
            return Just(nil).eraseToAnyPublisher()
        }
        return BrowserStore.shared.uiPublisher.map { state in
            state.profiles[profileID]?.dataStoreUUID ?? nil
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
    
    @ViewBuilder private var searchOverlay: some View {
        GeometryReader { geo in
            ManualTransitionView(models: snapshot.searchActive ? [ID<String>(raw: "x")] : []) { (model, phase) in
                MobileSearchOverlay(topSites: topSitesFetcher.topSites, transitionOut: phase != .inserted)
                    .animation(.spring(duration: 0.25, bounce: 0.15, blendDuration: 0.1), value: phase)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // somehow both are necessary to prevent keyboard from pushing the UI up
            // honestly i have no idea how this safe area shit works...
                .edgesIgnoringSafeArea(.all)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
    
    @ViewBuilder private var webContent: some View {
        if let paneID = snapshot.currentPane, let windowID, let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID) {
            #if os(iOS)
            DragToGoBackView(webContent: webContent) {
                WrappedWebView(webContent: webContent, shrunk: snapshot.isEmptyPage)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .edgesIgnoringSafeArea(.all)
            .overlay(alignment: .top) {
                loader.padding(6)
            }
            #else
            EmptyView()
            #endif
        } else {
            Color.clear
        }
    }
        
    @ViewBuilder private var loader: some View {
        if let webContentId = snapshot.currentPane, !snapshot.isEmptyPage {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.loadingProgress(webContentId: webContentId) }) { prog in
                LoadingIndicator(progress: prog == 1 ? nil : prog)
            }
        }
    }
    
    func setupOrbPos() {
        orbUnitX.minimum = 0
        orbUnitY.minimum = 0
        orbUnitX.maximum = 1
        orbUnitY.maximum = 1
        orbUnitX.value = 1
        orbUnitY.value = 1
    }
}

private struct MobileSidebarOverlay: View {
    var viewSize: CGSize
    @ObservedObject var orbYPos: MomentumValue // controls presentation of sidebar
    
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        // sidebar dismisser
        Color.black.opacity(remapClamped(x: orbYPos.rubberBandedValue, domainStart: 0.5, domainEnd: 0, rangeStart: 0, rangeEnd: 0.5))
            .onTapGesture {
                orbYPos.animate(toValue: 1, velocity: 0)
            }
            .edgesIgnoringSafeArea(.all)
        
        Group {
            #if os(iOS)
            OverscrollCatcher(options: .init(vertical: true, horizontal: false), stateDidChange: stateDidChange, didReleaseDrag: didReleaseDrag(_:)) { state in
                MobileDrawer()
                    .environment(\.windowID, windowID)
                    .environment(\.profileID, profileID)
//                    .overlay {
//                        if case .overscrolled(let values) = state, values.isDragging {
//                            Color.clear.onChange(of: values.realOffset.y) { yOffset in
//                                print("[d] Value changed")
//                                orbYPos.value = values.realOffset.y / offsetRange
//                            }
//                        }
//                    }
            }
            #else
            EmptyView()
            #endif
        }
        .withMobileDrawerContainer()
        .offset(y: orbYPos.rubberBandedValue * viewSize.height)
//        .offset(y: remap(x: orbYPos.rubberBandedValue, domainStart: 0, domainEnd: 1, rangeStart: 70, rangeEnd: viewSize.height + 50))
        .padding(.top, 120)
    }
    
    private var offsetRange: CGFloat {
        viewSize.height
    }
    
    func stateDidChange(_ state: OverscrollState) {
        if case .overscrolled(let values) = state, values.isDragging {
            orbYPos.value = values.realOffset.y / offsetRange
        }
    }
    
    func didReleaseDrag(_ state: OverscrollState) {
        if case .overscrolled(let values) = state {
            let dismissRatio = values.realOffset.y / offsetRange
            if abs(orbYPos.velocity) > 1 {
                orbYPos.animate(toValue: orbYPos.velocity < 0 ? 0 : 1, velocity: orbYPos.velocity)
            } else {
                orbYPos.animate(toValue: dismissRatio > 0.5 ? 1 : 0, velocity: orbYPos.velocity)
            }
        }
    }
}

private struct MobileContentSnapshot: Equatable {
    var searchActive = false
    var currentPane: ID<WebContent>?
    var isEmptyPage: Bool = true
    var profileID: ID<Profile>
    var windowBgColor: HSBA?
//    var windowSnapshot: WindowSnapshot
    
    init(state: BrowserState, windowID: ID<WindowState>) {
        guard let window = state.windows[windowID] else {
            self.profileID = .defaultProfile
            return
        }
        self.profileID = window.profile
        let paneData = state.currentPane(forWindow: windowID)
        self.currentPane = paneData?.id
        searchActive = window.searchOverlayActive
        self.isEmptyPage = paneData?.info.isEmptyPage ?? false
        self.windowBgColor = paneData?.info.underPageBackgroundColor
    }
}

struct SearchOrb: View {
    @ObservedObject var xPos: MomentumValue
    @ObservedObject var yPos: MomentumValue
    @Environment(\.windowID) private var windowID
    
    var orbSize: CGFloat = 100
    @State private var size = CGSize(width: 100, height: 100)
    @State private var unitPosAtStartOfDrag: UnitPoint?
    @State private var dragCanBeTap = false
    
    var body: some View {
        let dragging = unitPosAtStartOfDrag != nil
        Color.clear.overlay {
//            SearchOrbInner(dragInProgress: unitPosAtStartOfDrag != nil)
            DraggableFruit(dragVector: dragVector, distFromFloor: (1 - yPos.rubberBandedValue) * size.height, grabbed: dragging)
                .frame(both: orbSize)
                .opacity(remapClamped(x: yPos.rubberBandedValue, domainStart: 0.5, domainEnd: 0, rangeStart: 1, rangeEnd: 0)) // fade out as it gets super high
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged(dragged(_:))
                    .onEnded(endedGesture(_:))
                )
                .position(unitToRealPosition(posRubberBanded))
        }
        .measureSize({ self.size = $0 })
    }
    
    var dragVector: CGPoint {
        CGPoint(
            x: (xPos.velocity * 1.3).clamp(minVal: -1, maxVal: 1),
            y: (yPos.velocity * 1.3).clamp(minVal: -1, maxVal: 1)
        )
    }
    
    var pos: UnitPoint {
        UnitPoint(x: xPos.value, y: yPos.value)
    }
    
    var posRubberBanded: UnitPoint {
        UnitPoint(x: xPos.rubberBandedValue, y: yPos.rubberBandedValue)
    }
    
    func dragged(_ val: DragGesture.Value) {
        if unitPosAtStartOfDrag == nil {
            unitPosAtStartOfDrag = pos
            dragCanBeTap = true
        }
        let dist = sqrt(pow(val.translation.width, 2) + pow(val.translation.height, 2))
        if dist > 10 {
            dragCanBeTap = false
        }
        
        let realStartPos = unitToRealPosition(unitPosAtStartOfDrag ?? pos)
        let newPos = realPositionToUnit(CGPoint(x: realStartPos.x + val.translation.width, y: realStartPos.y + val.translation.height))
        xPos.value = newPos.x
        yPos.value = newPos.y
    }
    
    func endedGesture(_ val: DragGesture.Value) {
        if dragCanBeTap, let windowID {
            // show search
            BrowserStore.shared.modify { state in
                state.windows[windowID]?.searchOverlayActive = true
            }
        }
        
        let velocity = CGPoint(x: val.velocity.width / max(1, dragBounds.width), y: val.velocity.height / max(1, dragBounds.height))
        let stopPosX = xPos.expectedLandingPosition(velocity: velocity.x).roundToNearest([0, 0.5, 1])
        let stopPosY = yPos.expectedLandingPosition(velocity: velocity.y).roundToNearest([0, 1])
//        xPos.decelerate(velocity: velocity.x, completion: nil)
//        yPos.decelerate(velocity: velocity.y, completion: nil)
        xPos.animate(toValue: stopPosX, velocity: velocity.x)
        yPos.animate(toValue: stopPosY, velocity: velocity.y)
        
        unitPosAtStartOfDrag = nil
    }
    
    func realPositionToUnit(_ pos: CGPoint) -> UnitPoint {
        UnitPoint(
            x: (pos.x - dragBounds.minX) / max(1, dragBounds.width),
            y: (pos.y - dragBounds.minY) / max(1, dragBounds.height)
        )
    }
    
    func unitToRealPosition(_ pos: UnitPoint) -> CGPoint {
        CGPoint(x: pos.x * dragBounds.width + dragBounds.minX, y: pos.y * dragBounds.height + dragBounds.minY)
    }
    
    var dragBounds: CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: size.height)
            .insetBy(dx: orbSize / 2 + 20, dy: orbSize / 2 + 20)
    }
}

private struct SearchOrbInner: View {
    var dragInProgress = false
    
    var body: some View {
        Circle().fill(.thinMaterial)
            .overlay {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .opacity(0.5)
            }
            .scaleEffect(dragInProgress ? 1.1 : 1)
            .opacity(dragInProgress ? 0.8 : 1)
    }
}
