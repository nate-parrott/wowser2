import SwiftUI

public struct BrowserWindow: View {
    private let windowID: ID<WindowState>
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { WindowSnapshot(state: $0, id: self.windowID) }) { snapshot in
            WindowContent(snapshot: snapshot)
                .withBrowserContext(windowID: windowID, profileID: snapshot.profileID)
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
    }
    
    // Must have at least one, even if empty
    var panes: [PaneSnapshot]
    var profileID: ID<Profile>
    
    init(state: BrowserState, id: ID<WindowState>) {
        guard let window = state.windows[id] else {
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: false)]
            self.profileID = .defaultProfile
            return
        }
        self.profileID = window.profile
        guard let tabId = window.currentTab, let tab = state.tabs[tabId] else {
            self.panes = [PaneSnapshot(id: "", focused: true, searchActive: window.searchOverlayActive)]
            return
        }
        self.panes = tab.panes.enumerated().map({ (i, pane) in
            let focused = i == tab.focusedPaneIdx
            return PaneSnapshot(id: pane.id.raw, webContentId: pane.id, focused: focused, searchActive: focused && window.searchOverlayActive)
        })
    }
}

// Container that will host content and observe the correct data
private struct WindowContent: View {
    var snapshot: WindowSnapshot
    
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            HStack(spacing: 0) {
                ForEach(snapshot.panes) { pane in
                    PaneView(snapshot: pane, singlePane: snapshot.panes.count == 1)
                }
            }
            .edgesIgnoringSafeArea(.all)
        }
    }
}

fileprivate struct PaneView: View {
    var snapshot: WindowSnapshot.PaneSnapshot
    var singlePane: Bool
    
    @State private var searchText: String = ""
    @State private var selectedResultIndex = 0
    
    @Environment(\.windowID) private var windowID
    // Create Searcher with profile-specific history store
    @StateObject private var searcher = Searcher()
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(searchFocused: snapshot.searchActive, webContentID: snapshot.webContentId, searcher: searcher, searchText: $searchText, selectedResultIndex: $selectedResultIndex)
            
            content
                .overlay {
                    if snapshot.searchActive {
                        SearchResultsOverlay(searchText: $searchText, selectedResultIndex: $selectedResultIndex, searcher: searcher)
                    }
                }
        }
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
