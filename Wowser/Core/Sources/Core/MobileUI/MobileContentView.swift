import Combine
import SwiftUI

// Phone browser: the page fills the safe area as a rounded card over the
// space's colored backdrop. A draggable tangerine puck floats over it — tap it
// for the command bar; drag it up to lift the card and reveal the tray (its
// height drives the tray directly); drag sideways to park it left, center or
// right. Puck x and lift are MomentumValues: they track the finger exactly,
// then spring per-frame with the release velocity, and any new touch
// interrupts them.

public struct MobileContentView: View {
    public var windowID: ID<WindowState>

    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }

    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { MobileContentSnapshot(state: $0, windowID: windowID) }) { snapshot in
            _MobileContentView(snapshot: snapshot, windowID: windowID)
                .environment(\.profileID, snapshot.profileID)
        }
        .environment(\.windowID, windowID)
        .onAppear {
            BrowserStore.shared.modify { state in
                if state.windows[windowID] == nil {
                    state.windows[windowID] = .init(id: windowID, profile: .defaultProfile)
                }
            }
        }
    }
}

private struct MobileContentSnapshot: Equatable {
    var profileID: ID<Profile> = .defaultProfile
    var theme: SpaceTheme?
    var imageInfo: SpaceImageInfo?
    var searchActive = false
    var currentPane: ID<WebContent>?
    var currentTabID: ID<Tab>?
    var isEmptyPage = true
    var isAgentPage = false

    init(state: BrowserState, windowID: ID<WindowState>) {
        guard let window = state.windows[windowID] else { return }
        profileID = window.profile
        let profile = state.profiles[window.profile]
        theme = profile?.theme
        imageInfo = profile?.imageInfo
        searchActive = window.searchOverlayActive
        currentTabID = window.currentTab
        let pane = state.currentPane(forWindow: windowID)
        currentPane = pane?.id
        isEmptyPage = pane?.info.isEmptyPage ?? true
        isAgentPage = pane?.info.url.flatMap(NativePageKey.init)?.isAgent == true
    }
}

private struct _MobileContentView: View {
    var snapshot: MobileContentSnapshot
    var windowID: ID<WindowState>

    @StateObject private var puckX = MomentumValue(initialValue: 0, scale: 1, params: .mobilePuck)
    @StateObject private var lift = MomentumValue(initialValue: 0, scale: 1, params: .mobilePuck)
    @State private var layout = MobileLayout(size: CGSize(width: 390, height: 844), safeArea: EdgeInsets())
    @State private var settingsPresented = false
    @State private var puckSide: MobilePuckSide = .trailing
    @StateObject private var keyboard = MobileKeyboardObserver()

    var body: some View {
        GeometryReader { geo in
            let layout = MobileLayout(
                size: CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                             height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom),
                safeArea: geo.safeAreaInsets
            )
            ZStack(alignment: .topLeading) {
                MobileSpaceBackdrop(theme: snapshot.theme, imageInfo: snapshot.imageInfo)
                    .animation(.easeInOut(duration: 0.35), value: snapshot.profileID)

                Group {
                    MobileTrayLayer(windowID: windowID, layout: layout, lift: lift, accent: accent.accent, openSettings: { settingsPresented = true })

                    card
                        .modifier(CardLiftModifier(layout: layout, lift: lift))

                    MobileBackToChatPill(windowID: windowID, currentTabID: snapshot.currentTabID, layout: layout, puckX: puckX, lift: lift, hidden: snapshot.searchActive)
                }
                // The command bar fades everything behind it toward the backdrop.
                .opacity(snapshot.searchActive ? 0.3 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.9), value: snapshot.searchActive)

                MobilePuck(layout: layout, x: puckX, lift: lift, hidden: snapshot.searchActive || keyboard.height > 0, onPark: parkPuck) {
                    BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = true }
                }

                MobileCommandBar(windowID: windowID, presented: snapshot.searchActive, layout: layout, accent: accent.accent, onAccent: accent.onAccent)

                if !snapshot.isEmptyPage, !snapshot.isAgentPage, !snapshot.searchActive {
                    loader
                        .padding(.top, layout.safeArea.top + 4)
                        .padding(.horizontal, 24)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .ignoresSafeArea()
            .onAppearOrChange(of: layout) { self.layout = $0 }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .environment(\.colorScheme, .dark)
        .tint(accent.accent)
        .onAppearOrChange(of: layout) { configureMomentum(for: $0) }
        #if DEBUG
        .onAppear(perform: applyDebugLaunchState)
        #endif
        .onChange(of: snapshot.currentTabID) { _, tabID in
            MobileChatReturn.shared.forgetIfLeft(windowID: windowID, currentTabID: tabID)
        }
        #if os(iOS)
        .modifier(DeviceShakeViewModifier(action: { settingsPresented = true }))
        #endif
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
                .environment(\.colorScheme, .dark)
        }
    }

    private var accent: SpaceAccent {
        SpaceAccent.forSpace(theme: snapshot.theme, imageInfo: snapshot.imageInfo) ?? .system
    }

    // MARK: - Card

    @ViewBuilder private var card: some View {
        let shape = RoundedRectangle(cornerRadius: MobileLayout.cardCornerRadius, style: .continuous)
        Group {
            if let paneID = snapshot.currentPane,
               let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID) {
                #if os(iOS)
                DragToGoBackView(webContent: webContent) {
                    WrappedWebView(webContent: webContent, shrunk: snapshot.isEmptyPage)
                }
                #endif
            } else {
                Color.white.opacity(0.05)
            }
        }
        .environment(\.colorScheme, snapshot.isAgentPage ? .dark : systemColorScheme)
        .environment(\.mobilePuckSide, puckSide)
        .background {
            if snapshot.isAgentPage {
                shape.fill(Color.white.opacity(0.05))
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(snapshot.isAgentPage ? 0.14 : 0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(snapshot.isAgentPage ? 0 : 0.3), radius: 16, y: 12)
        .frame(width: layout.cardRect.width, height: cardHeight)
        .frame(height: layout.cardRect.height, alignment: .top)
        .offset(x: layout.cardRect.minX, y: layout.cardRect.minY)
        .animation(.spring(response: 0.3, dampingFraction: 0.92), value: cardHeight)
    }

    /// Chats keep their input above the keyboard; web pages handle it themselves.
    private var cardHeight: CGFloat {
        guard snapshot.isAgentPage, !snapshot.searchActive, keyboard.height > 0 else { return layout.cardRect.height }
        return layout.cardRect.height - max(0, keyboard.height - layout.safeArea.bottom) - 8
    }

    /// Pages keep the user's own appearance; only our chrome is forced dark.
    @Environment(\.colorScheme) private var systemColorScheme

    @ViewBuilder private var loader: some View {
        if let webContentId = snapshot.currentPane {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.loadingProgress(webContentId: webContentId) }) { prog in
                LoadingIndicator(progress: prog == 1 ? nil : prog)
            }
        }
    }

    #if DEBUG
    /// Screenshot hooks (simctl can't tap): `WOWSER_MOBILE_URL=<url>` opens a
    /// page, `WOWSER_MOBILE_ASK=<query>` opens a chat, `WOWSER_MOBILE_TRAY=open`
    /// starts with the tray up, `WOWSER_MOBILE_CMD=<query>` opens the command
    /// bar with a query typed.
    private func applyDebugLaunchState() {
        // After the app's launch-time "open the command bar" scene-phase hook.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: _applyDebugLaunchState)
    }

    private func _applyDebugLaunchState() {
        let env = ProcessInfo.processInfo.environment
        if let url = env["WOWSER_MOBILE_URL"].flatMap(URL.init(string:)) {
            BrowserStore.shared.modify { state in
                state.openTab(url: url, activate: true, windowID: windowID)
                state.windows[windowID]?.searchOverlayActive = false
            }
        }
        if let ask = env["WOWSER_MOBILE_ASK"] {
            AgentChatTabs.openChatTab(query: ask, windowID: windowID)
            BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = false }
        }
        if env["WOWSER_MOBILE_TRAY"] == "open" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                lift.animate(toValue: layout.puckTravel, velocity: 0)
            }
        }
        if env["WOWSER_MOBILE_CMD"] != nil {
            BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = true }
        }
    }
    #endif

    private func parkPuck(at x: CGFloat) {
        let snaps = layout.puckSnapXs
        puckSide = x == snaps.first ? .leading : x == snaps.last ? .trailing : .center
    }

    private func configureMomentum(for layout: MobileLayout) {
        let wasOpen = lift.value > self.layout.puckTravel / 2
        puckX.minimum = layout.puckSnapXs.first
        puckX.maximum = layout.puckSnapXs.last
        lift.minimum = 0
        lift.maximum = layout.puckTravel
        if puckX.value == 0 || !layout.puckSnapXs.contains(puckX.value) && !puckX.animating {
            puckX.value = layout.puckSnapXs.last ?? 0
        }
        if !lift.animating {
            lift.value = wasOpen ? layout.puckTravel : 0
        }
    }
}

/// Lifts the card with the tray. A ViewModifier so per-frame lift changes
/// don't re-evaluate the web view.
private struct CardLiftModifier: ViewModifier {
    var layout: MobileLayout
    @ObservedObject var lift: MomentumValue

    func body(content: Content) -> some View {
        let progress = lift.rubberBandedValue / max(1, layout.puckTravel)
        content
            .offset(y: -progress * layout.cardTravel)
            .overlay {
                // While the tray is up, tapping the peeking page closes it.
                if lift.value > 1 {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                        .offset(x: layout.cardRect.minX, y: layout.cardRect.minY - progress * layout.cardTravel)
                        .onTapGesture { lift.animate(toValue: 0, velocity: 0) }
                        .mobileTrayDrag(lift: lift, travel: layout.puckTravel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
    }
}

// MARK: - Tray layer

private struct MobileTrayLayer: View {
    var windowID: ID<WindowState>
    var layout: MobileLayout
    @ObservedObject var lift: MomentumValue
    var accent: Color
    var openSettings: () -> Void

    @AppStorage(DefaultsKeys.allWindowsShareTabs.rawValue) private var allWindowsShareTabs = true

    var body: some View {
        let progress = lift.rubberBandedValue / max(1, layout.puckTravel)
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.mobileTraySnapshot(windowID: windowID, shareTabsAcrossWindows: allWindowsShareTabs) }) { snapshot in
            MobileTray(snapshot: snapshot, accent: accent, didPick: { lift.animate(toValue: 0, velocity: 0) }, openSettings: openSettings)
        }
        .frame(width: layout.size.width, height: layout.trayHeight)
        .contentShape(Rectangle())
        .mobileTrayDrag(lift: lift, travel: layout.puckTravel)
        .offset(y: layout.trayTop + (1 - progress) * 600)
        .opacity(min(1, max(0, progress * 1.6)))
        .allowsHitTesting(lift.value > 1)
    }
}

// MARK: - Puck

private struct MobilePuck: View {
    var layout: MobileLayout
    @ObservedObject var x: MomentumValue
    @ObservedObject var lift: MomentumValue
    var hidden: Bool
    /// The snap x the puck is heading for after a drag.
    var onPark: (CGFloat) -> Void
    var onTap: () -> Void

    @State private var dragStart: (x: Double, lift: Double)?
    @State private var dragIsTap = false

    var body: some View {
        DraggableFruit(dragVector: dragVector, distFromFloor: lift.rubberBandedValue, grabbed: dragStart != nil)
            .frame(width: MobileLayout.puckSize, height: MobileLayout.puckSize)
            .contentShape(Circle().inset(by: 10))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged(dragged)
                    .onEnded(ended)
            )
            .position(x: x.rubberBandedValue, y: layout.puckRestY - lift.rubberBandedValue)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.spring(response: 0.26, dampingFraction: 0.9), value: hidden)
            .accessibilityElement()
            .accessibilityLabel("New tab")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
    }

    /// Velocity in screens per second, ×1.3, clamped — what DraggableFruit
    /// tilts and swings its leaves by.
    private var dragVector: CGPoint {
        CGPoint(
            x: (x.velocity / max(1, layout.size.width) * 1.3).clamp(minVal: -1, maxVal: 1),
            y: (-lift.velocity / max(1, layout.puckTravel) * 1.3).clamp(minVal: -1, maxVal: 1)
        )
    }

    private func dragged(_ value: DragGesture.Value) {
        if dragStart == nil {
            // Setting `.value` stops any running spring: the touch takes over.
            dragStart = (x.value, lift.value)
            dragIsTap = true
        }
        guard let start = dragStart else { return }
        if hypot(value.translation.width, value.translation.height) > 10 {
            dragIsTap = false
        }
        x.value = start.x + Double(value.translation.width)
        lift.value = start.lift - Double(value.translation.height)
    }

    private func ended(_ value: DragGesture.Value) {
        dragStart = nil
        // Spring from where the puck is drawn, not from the raw (un-rubber-
        // banded) finger position past the ends.
        if x.rubberBandedValue != x.value { x.value = x.rubberBandedValue }
        if lift.rubberBandedValue != lift.value { lift.value = lift.rubberBandedValue }
        let v = value.velocity
        let projectedX = CGFloat(x.value) + v.width * 0.12
        let snapX = layout.puckSnapXs.min(by: { abs($0 - projectedX) < abs($1 - projectedX) }) ?? CGFloat(x.value)
        x.animate(toValue: snapX, velocity: dragIsTap ? 0 : v.width)
        onPark(snapX)
        if dragIsTap {
            lift.animate(toValue: lift.value > layout.puckTravel / 2 ? layout.puckTravel : 0, velocity: 0)
            onTap()
            return
        }
        let projectedLift = CGFloat(lift.value) - v.height * 0.15
        lift.animate(toValue: projectedLift > layout.puckTravel / 2 ? layout.puckTravel : 0, velocity: -v.height)
    }
}

// MARK: - Back to chat

private struct MobileBackToChatPill: View {
    var windowID: ID<WindowState>
    var currentTabID: ID<Tab>?
    var layout: MobileLayout
    @ObservedObject var puckX: MomentumValue
    @ObservedObject var lift: MomentumValue
    var hidden: Bool
    @ObservedObject private var chatReturn = MobileChatReturn.shared

    private static let size = CGSize(width: 124, height: 36)

    var body: some View {
        let visible = !hidden && lift.value < 1 && chatReturn.entry(windowID: windowID, currentTabID: currentTabID) != nil
        Button { chatReturn.returnToChat(windowID: windowID) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 12, weight: .bold))
                Text("Back to chat")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: Self.size.height)
            .mobileGlass(.capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .position(target)
        // Trails the puck on a looser, critically damped spring.
        .animation(.spring(response: 0.45, dampingFraction: 1), value: target)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: visible)
    }

    /// Beside the puck, on its inner side, vertically centered on it.
    private var target: CGPoint {
        let px = puckX.rubberBandedValue
        let py = layout.puckRestY - lift.rubberBandedValue
        let gap: CGFloat = 30 + 12 + Self.size.width / 2
        return CGPoint(x: px > layout.size.width / 2 + 1 ? px - gap : px + gap, y: py)
    }
}
