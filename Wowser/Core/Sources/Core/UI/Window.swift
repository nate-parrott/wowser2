import SwiftUI

public struct BrowserWindow: View {
    private let windowID: ID<WindowState>
    public var unmount = false
    public var isFullscreen = false
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        if !unmount {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { WindowSnapshot(state: $0, id: self.windowID) }) { snapshot in
                ZStack(alignment: .topLeading) {
                    WindowContent(snapshot: snapshot)
                        .withBrowserContext(windowID: windowID, profileID: snapshot.profileID)
                        .environment(\.isFullscreen, isFullscreen)
                }
                .coordinateSpace(name: "BrowserWindowRoot")
            }
        }
    }
}

// Window snapshot with minimal data
struct WindowSnapshot: Equatable {
    struct PaneSnapshot: Equatable, Identifiable {
        var id: String
        var webContentId: Core.ID<WebContent>?
        var focused: Bool
        var searchActive: Bool
        var emptyPage: Bool
        var colorScheme: ContentColorScheme?
        var isPickingSelector: Bool
        var weight: Double = 1.0
        var topbarLocked: Bool
    }
    
    // Must have at least one, even if empty
    var panes: [PaneSnapshot]
    var tabId: ID<Tab>?
    var profileID: ID<Profile>
    var windowID: ID<WindowState>
    var sidebarLocked: Bool
    var swipeGestureOffset: Int?
    var hasToast: Bool
    var anyPaneHasSearchActive: Bool {
        panes.filter({ $0.searchActive }).count > 0
    }
    
    init(state: BrowserState, id: ID<WindowState>) {
        self.windowID = id
        guard let window = state.windows[id] else {
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: false, emptyPage: true, isPickingSelector: false, topbarLocked: false)]
            self.profileID = .defaultProfile
            self.sidebarLocked = false
            self.hasToast = false
            return
        }
        self.sidebarLocked = window.sidebarLocked
        self.tabId = window.currentTab
        self.profileID = window.profile
        self.swipeGestureOffset = window.swipeGestureOffset
        self.hasToast = window.currentToast != nil
        let focusSnap = state.focusState(windowID: id)
        guard let tabId = window.currentTab, let tab = state.tabs[tabId] else {
//            let emptyOmnibox: Bool
//            if case .omnibox = focusSnap.target { emptyOmnibox = true } else { emptyOmnibox = false }
            let searchActive = focusSnap.target == .emptyWindowOmnibox(windowID)
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: searchActive, emptyPage: true, isPickingSelector: false, topbarLocked: window.sidebarLocked)]
            return
        }
        self.panes = tab.panes.enumerated().map({ (i, pane) in
            let focused = i == tab.focusedPaneIdx
            // searchActive is *exactly* "the focus snap says omnibox" for this pane.
            // Single rule, no separate computation, can't drift out of sync.
            let searchActive = focusSnap.target == .omnibox(pane: pane.id)
            return PaneSnapshot(
                id: pane.id.raw,
                webContentId: pane.id,
                focused: focused,
                searchActive: searchActive,
                emptyPage: pane.info.isEmptyPage,
                colorScheme: pane.info.colorScheme,
                isPickingSelector: window.pickingSelectorInPaneId == pane.id,
                weight: pane.weight ?? 1.0,
                topbarLocked: window.sidebarLocked
            )
        })
    }
}

extension WebContent.Info {
    var isEmptyPage: Bool {
        url == nil || url == .aboutBlank
    }
}

// Container that will host content and observe the correct data
private struct WindowContent: View {
    var snapshot: WindowSnapshot
    
    @State private var topHovered = false
//    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var sidebarHovered = false
    
    var body: some View {
        let topbarLocked = snapshot.sidebarLocked
        let justWebpage = !snapshot.sidebarLocked && !topbarLocked
        
        HStack(spacing: 0) {
            if snapshot.sidebarLocked {
                Sidebar(floating: false)
                Divider()
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Content:
            VStack(spacing: 0) {
                TabStack3D(snapshot: snapshot, topbarVisible: topbarVisible)
                ToastViewer()
            }
            .animation(.spring(duration: 0.2, bounce: 0.2, blendDuration: 0.1), value: snapshot.hasToast)
//            .edgesIgnoringSafeArea(.all)
        }
        .modifier(JustWebpageScrimModifier(active: justWebpage))
        .overlay(alignment: .leading) {
            if !snapshot.sidebarLocked {
                Sidebar(floating: true)
                    .withFloatingSidebarContainer()
//                    .padding(8)
                    .offset(x: sidebarHovered ? 0 : -UIConstants.sidebarWidth - 20)
                    .animation(.spring(duration: 0.16, bounce: 0.2, blendDuration: 0.1), value: sidebarHovered)
                    .edgesIgnoringSafeArea(.all)
            }
        }
        .background {
            Color.clear
                .trackMouseOutsideWindow(onMouseMoved: { self.mouseMoved($0, rect: $1) })
                .edgesIgnoringSafeArea(.all)
        }
        .background { WindowBG() }
        .edgesIgnoringSafeArea(.all)
    }
    
    private var topbarVisible: Bool {
        let topbarLocked = snapshot.sidebarLocked
        return topHovered || topbarLocked || snapshot.anyPaneHasSearchActive
    }
    
    private func mouseMoved(_ pt: CGPoint, rect: CGRect) {
        // Update topbar hover:
        let fixedSidebarWidth = snapshot.sidebarLocked ? UIConstants.sidebarWidth : 0
        let topbarHoverZone = CGRect(
            x: fixedSidebarWidth,
            y: -50,
            width: rect.width - fixedSidebarWidth,
            height: 50 + (topbarVisible ? UIConstants.macHeaderHeight + 40 : 5)
        )
        let topHoveredNow = topbarHoverZone.contains(pt)
        if topHovered != topHoveredNow {
            topHovered = topHoveredNow
        }
        
        // Update sidebar hover:
        var sidebarHovered = false
        if !snapshot.sidebarLocked {
            let hoverZone = CGRect(x: -150, y: 0, width: self.sidebarHovered ? UIConstants.sidebarWidth + 8 + 10 + 150 : 150 + 4, height: rect.height)
            sidebarHovered = hoverZone.contains(pt)
        }
        if self.sidebarHovered != sidebarHovered {
            self.sidebarHovered = sidebarHovered
        }
    }
}

private struct JustWebpageScrimModifier: ViewModifier {
    var active = true
    
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: active ? 10 : 0))
            .shadow(color: Color.black.opacity(active ? 0.1 : 0), radius: 3, x: 0, y: 1)
            .padding(active ? 8 : 0)
    }
}

private struct WindowBG: View {
    var body: some View {
        ZStack {
            TransparentBg()
            LinearGradient(colors: [Color.white.opacity(0), Color.accentColor.opacity(0.1)], startPoint: .top, endPoint: .bottom)
        }
    }
}

// Empty tab view
private struct EmptyTabView: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        Text("No tab selected")
            .font(.title)
            .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(.windowBackgroundColor))
        #endif
    }
    
    private func createNewTab(windowID: ID<WindowState>) {
        BrowserStore.shared.modify { state in
            let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init())])
            let location = state.insertionIndex(window: windowID, spawningTabId: nil)
            state.insertTab(tab, location: location, inWindow: windowID)
            state.activate(tabId: tab.id, in: windowID)
        }
    }
}

public struct BrowserWindow_Previews: PreviewProvider {
    public static var previews: some View {
        BrowserWindow(windowID: ID<WindowState>(raw: "w0"))
    }
}

extension View {
    @ViewBuilder
    func withFloatingSidebarContainer() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        
        self.background(.regularMaterial)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 0)
    }
}

struct SwipeDebugView: View {
    @Environment(\.windowID) private var windowID
    
    struct Snapshot: Equatable {
        let offset: Int?
        
        init(state: BrowserState, windowID: ID<WindowState>) {
            offset = state.windows[windowID]?.swipeGestureOffset
        }
    }
    
    var body: some View {
        if let windowID {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { Snapshot(state: $0, windowID: windowID) }) { snapshot in
                if let offset = snapshot.offset {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Swipe: \(offset)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color.red)
                    .cornerRadius(6)
                    .padding()
                }
            }
        }
    }
}

extension BrowserState {
    func loadingProgress(webContentId: ID<WebContent>) -> Double? {
        if let tabId = paneToTabMapping[webContentId], let tab = tabs[tabId], let pane = tab.panes[webContentId] {
            return pane.info.estimatedProgress
        }
        return nil
    }
}
