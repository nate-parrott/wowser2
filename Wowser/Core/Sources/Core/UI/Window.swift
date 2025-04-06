import SwiftUI

public struct BrowserWindow: View {
    private let windowID: ID<WindowState>
    public var unmount = false
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        if !unmount {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { WindowSnapshot(state: $0, id: self.windowID) }) { snapshot in
                WindowContent(snapshot: snapshot)
                    .withBrowserContext(windowID: windowID, profileID: snapshot.profileID)
            }
        }
    }
}

// Window snapshot with minimal data
private struct WindowSnapshot: Equatable {
    struct PaneSnapshot: Equatable, Identifiable {
        var id: String
        var webContentId: ID<WebContent>?
        var focused: Bool
        var searchActive: Bool
        var emptyPage: Bool
        var colorScheme: ContentColorScheme?
    }
    
    // Must have at least one, even if empty
    var panes: [PaneSnapshot]
    var profileID: ID<Profile>
    var sidebarLocked: Bool
    var anyPaneHasSearchActive: Bool {
        panes.filter({ $0.searchActive }).count > 0
    }
    
    init(state: BrowserState, id: ID<WindowState>) {
        guard let window = state.windows[id] else {
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: false, emptyPage: true)]
            self.profileID = .defaultProfile
            sidebarLocked = false
            return
        }
        self.sidebarLocked = window.sidebarLocked
        self.profileID = window.profile
        guard let tabId = window.currentTab, let tab = state.tabs[tabId] else {
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: window.searchOverlayActive, emptyPage: true)]
            return
        }
        self.panes = tab.panes.enumerated().map({ (i, pane) in
            let focused = i == tab.focusedPaneIdx
            return PaneSnapshot(
                id: pane.id.raw,
                webContentId: pane.id,
                focused: focused,
                searchActive: focused && window.searchOverlayActive,
                emptyPage: pane.info.url == nil || pane.info.url == .aboutBlank,
                colorScheme: pane.info.colorScheme)
        })
    }
}

// Container that will host content and observe the correct data
private struct WindowContent: View {
    var snapshot: WindowSnapshot
    
    @State private var topHovered = false
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var sidebarHovered = false
    
    var body: some View {
        HStack(spacing: 0) {
            if snapshot.sidebarLocked {
                Sidebar(floating: false)
                    .background { TransparentBg() }
                Divider()
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Content:
            HStack(spacing: 0) {
                ForEach(snapshot.panes) { pane in
                    PaneView(snapshot: pane, singlePane: snapshot.panes.count == 1, topbarVisible: topbarVisible || pane.emptyPage, toolbarColorScheme: pane.colorScheme)
                }
            }
            .edgesIgnoringSafeArea(.all)
            .overlay(alignment: .topTrailing) {
                ToastViewer()
            }
        }
        .overlay(alignment: .leading) {
            if !snapshot.sidebarLocked {
                Sidebar(floating: true)
                    .withFloatingSidebarContainer()
                    .padding(8)
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
    }
    
    private var topbarVisible: Bool {
        topHovered || topbarLocked || snapshot.anyPaneHasSearchActive
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

fileprivate struct PaneView: View {
    var snapshot: WindowSnapshot.PaneSnapshot
    var singlePane: Bool
    var topbarVisible: Bool
    var toolbarColorScheme: ContentColorScheme?
    
    @State private var searchText: String = ""
    @State private var selectedResultIndex = 0
    
    @Environment(\.windowID) private var windowID
    // Create Searcher with profile-specific history store
    @StateObject private var searcher = Searcher()
    @Environment(\.profileID) private var profileID
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var size: CGSize = .zero
    
    var body: some View {
        ZStack(alignment: .top) {
            content
                .padding(.top, topbarLocked ? UIConstants.macHeaderHeight : 0)
                .scaleEffect(y: !topbarLocked && topbarVisible ? (size.height - UIConstants.macHeaderHeight) / max(size.height, 1) : 1, anchor: .bottom)
//                .opacity(snapshot.searchActive ? 0.1 : 1)
            
            if snapshot.searchActive {
                SearchResultsOverlay(searchText: $searchText, selectedResultIndex: $selectedResultIndex, searcher: searcher)
                    .padding(.top, UIConstants.macHeaderHeight)
            }
            
            ToolbarView(
                searchFocused: snapshot.searchActive,
                webContentID: snapshot.webContentId,
                fgColor: toolbarColorScheme?.foreground,
                searcher: searcher,
                searchText: $searchText,
                selectedResultIndex: $selectedResultIndex
            )
                .modifier(WithContentColorScheme(scheme: toolbarColorScheme))
                .shadow(color: Color.black.opacity(topbarVisible ? 0.1 : 0), radius: 5, x: 0, y: 0)
                .animation(.niceDefault, value: toolbarColorScheme)
                .offset(y: topbarVisible ? 0 : -UIConstants.macHeaderHeight)
//                .scaleEffect(y: topbarVisible ? 1 : 0.0001, anchor: .top)
        }
        .measureSize { self.size = $0 }
        .overlay {
            if snapshot.focused, !singlePane {
                Rectangle().strokeBorder(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onAppearOrChange(of: profileID) { profileID in
            searcher.profileID = profileID
        }
        .onChange(of: searchText) { newValue in
            searcher.query = newValue
            selectedResultIndex = 0 // Reset selection when query changes
        }
        .onChange(of: snapshot.searchActive) {
            if !$0 {
                searchText = ""
            }
        }
        .animation(.niceDefault(duration: 0.12), value: topbarVisible)
//        .animation(.spring(response: 0.1, dampingFraction: 0.8, blendDuration: 0.05), value: topbarVisible)
    }
    
    @ViewBuilder private var content: some View {
        ZStack {
            if let webContentId = snapshot.webContentId, let windowID, let webContent = BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID) {
                WrappedWebView(webContent: webContent, isFocused: snapshot.focused)
            } else {
                Color.clear
            }
        }
    }
}

//// Snapshot for tab content
//private struct TabContentSnapshot: Equatable {
//    let windowID: ID<WindowState>
//    let currentTabID: ID<Tab>?
//    let hasTab: Bool
//    
//    init(windowID: ID<WindowState>, currentTabID: ID<Tab>?, tabs: [ID<Tab>: Tab]) {
//        self.windowID = windowID
//        self.currentTabID = currentTabID
//        self.hasTab = currentTabID != nil && tabs[currentTabID!] != nil
//    }
//}

//// View for the tab content
//private struct TabContentView: View {
//    let tabID: ID<Tab>
//    private let browserStore = BrowserStore.shared
//    
//    var body: some View {
//        WithSnapshotMain(store: browserStore, snapshot: { TabLayoutSnapshot(tab: $0.tabs[tabID]) }) { snapshot in
//            if let snapshot {
//                SplitPanesView(
//                    paneIDs: snapshot.paneIDs,
//                    focusedPaneIdx: snapshot.focusedPaneIdx
//                )
//                .id(tabID)
//            } else {
//                // Loading or error state
//                VStack {
//                    ProgressView()
//                    Text("Loading...")
//                        .foregroundColor(.secondary)
//                        .padding()
//                }
//            }
//        }
//    }
//}
//
//// Tab layout snapshot
//private struct TabLayoutSnapshot: Equatable {
//    let paneIDs: [ID<WebContent>]
//    let focusedPaneIdx: Int
//    
//    init?(tab: Tab?) {
//        guard let tab else { return nil }
//        self.paneIDs = tab.panes.map { $0.id }
//        self.focusedPaneIdx = tab.focusedPaneIdx
//    }
//}

//// Single pane view
//private struct SinglePaneView: View {
//    let paneID: ID<WebContent>
//    @Environment(\.windowID) private var windowID
//    @State private var webContent: WebContent?
//    private let browserStore = BrowserStore.shared
//    
//    var body: some View {
//        ZStack {
//            // Web content
//            if let webContent = webContent {
//                WrappedWebView(webContent: webContent, isFocused: true)
//                    .id(webContent)
//            } else {
//                // Loading or error state
//                VStack {
//                    ProgressView()
//                    Text("Loading...")
//                        .foregroundColor(.secondary)
//                        .padding()
//                }
//            }
//        }
//        .onAppearOrChange(of: paneID) { id in
//            // Get the WebContent from BrowserStore
//            webContent = browserStore.getOrCreateWebContent(forId: id, toBeActiveInWindow: windowID!)
//        }
//    }
//}

//// Split panes view
//private struct SplitPanesView: View {
//    let paneIDs: [ID<WebContent>]
//    let focusedPaneIdx: Int
//    @State private var webContentMap = [ID<WebContent>: WebContent]()
//    private let browserStore = BrowserStore.shared
//    @Environment(\.windowID) private var windowID
//    
//    var body: some View {
//        GeometryReader { geometry in
//            splitPanesContainer(geometry: geometry)
//                .background(Color.gray.opacity(0.1))
//        }
//        .onAppear {
//            loadWebContents()
//        }
//        .onChange(of: paneIDs) { _ in
//            loadWebContents()
//        }
//    }
//    
//    // Container for all panes
//    private func splitPanesContainer(geometry: GeometryProxy) -> some View {
//        HStack(spacing: 1) {
//            ForEach(Array(paneIDs.enumerated()), id: \.element.id) { index, paneID in
//                paneView(
//                    paneID: paneID,
//                    index: index,
//                    width: geometry.size.width / CGFloat(paneIDs.count)
//                )
//            }
//        }
//    }
//    
//    // Individual pane view
//    private func paneView(paneID: ID<WebContent>, index: Int, width: CGFloat) -> some View {
//        ZStack {
//            if let webContent = webContentMap[paneID] {
//                WrappedWebView(webContent: webContent, isFocused: index == focusedPaneIdx)
//            } else {
//                paneLoadingView
//            }
//        }
//        .frame(width: width)
//        .background(Color.white)
//        .overlay(focusOverlay(index: index))
//    }
//    
//    // Loading state for a pane
//    private var paneLoadingView: some View {
//        ProgressView()
//    }
//    
//    // Focus indicator overlay
//    @ViewBuilder
//    private func focusOverlay(index: Int) -> some View {
//        if index == focusedPaneIdx {
//            RoundedRectangle(cornerRadius: 0)
//                .stroke(Color.blue, lineWidth: 2)
//                .opacity(0.7)
//        }
//    }
//    
//    // Load all web contents for the panes
//    private func loadWebContents() {
//        for paneID in paneIDs {
//            if let webContent = browserStore.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID!) {
//                webContentMap[paneID] = webContent
//            }
//        }
//    }
//}

// Empty tab view
private struct EmptyTabView: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        Text("No tab selected")
            .font(.title)
            .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
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

private extension View {
    @ViewBuilder
    func withFloatingSidebarContainer() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        
        self.background(.thinMaterial)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 0)
    }
}
