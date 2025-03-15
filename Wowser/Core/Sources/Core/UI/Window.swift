import SwiftUI

public struct BrowserWindow: View {
    private let windowID: ID<WindowState>
    private let browserStore = BrowserStore.shared
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        WithSnapshot(store: browserStore) { state in
            // Create a minimal snapshot with just the data we need
            WindowSnapshot(
                windowID: windowID,
                windows: state.windows,
                profiles: state.profiles
            )
        } main: { snapshot in
            if let snapshot = snapshot {
                WindowContentContainer(
                    windowID: windowID, 
                    profileID: snapshot.profileID,
                    searchOverlayActive: snapshot.searchOverlayActive
                )
                .withBrowserContext(windowID: windowID, profileID: snapshot.profileID)
            } else {
                // Loading state
                ProgressView()
            }
        }
    }
}

// Window snapshot with minimal data
private struct WindowSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    let searchOverlayActive: Bool
    
    init(windowID: ID<WindowState>, windows: [ID<WindowState>: WindowState], profiles: [ID<Profile>: Profile]) {
        self.windowID = windowID
        
        // Extract window state
        let window = windows[windowID]
        
        // Extract search overlay state
        self.searchOverlayActive = window?.searchOverlayActive ?? false
        
        // Extract profile ID
        if let profileID = window?.profile {
            self.profileID = profileID
        } else {
            // Default to the first profile if window not found
            self.profileID = profiles.keys.first ?? ID<Profile>(raw: "")
        }
    }
}

// Container that will host content and observe the correct data
private struct WindowContentContainer: View {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    let searchOverlayActive: Bool
    private let browserStore = BrowserStore.shared
    
    var body: some View {
        WithSnapshot(store: browserStore) { state in
            TabContentSnapshot(
                windowID: windowID,
                currentTabID: state.windows[windowID]?.currentTab,
                tabs: state.tabs
            )
        } main: { snapshot in
            ZStack {
                HStack(spacing: 0) {
                    // Sidebar
                    Sidebar()
                    
                    // Main content area
                    if let snapshot = snapshot, 
                       let currentTabID = snapshot.currentTabID,
                       snapshot.hasTab {
                        TabContentView(tabID: currentTabID)
                    } else {
                        // Empty state - no tab selected
                        EmptyTabView(windowID: windowID)
                    }
                }
                
                // Overlay the search if active
                if searchOverlayActive {
                    SearchOverlay()
                        .id(profileID)
                        .edgesIgnoringSafeArea(.all)
                }
            }
            .background(Color(.windowBackgroundColor))
        }
    }
}

// Snapshot for tab content
private struct TabContentSnapshot: Equatable {
    let windowID: ID<WindowState>
    let currentTabID: ID<Tab>?
    let hasTab: Bool
    
    init(windowID: ID<WindowState>, currentTabID: ID<Tab>?, tabs: [ID<Tab>: Tab]) {
        self.windowID = windowID
        self.currentTabID = currentTabID
        self.hasTab = currentTabID != nil && tabs[currentTabID!] != nil
    }
}

// View for the tab content
private struct TabContentView: View {
    let tabID: ID<Tab>
    private let browserStore = BrowserStore.shared
    
    var body: some View {
        WithSnapshotMain(store: browserStore, snapshot: { TabLayoutSnapshot(tab: $0.tabs[tabID]) }) { snapshot in
            if let snapshot {
                Group {
                    if snapshot.paneIDs.count == 1 {
                        // Single pane
                        SinglePaneView(paneID: snapshot.paneIDs[0])
                    } else {
                        // Split panes
                        SplitPanesView(
                            paneIDs: snapshot.paneIDs,
                            focusedPaneIdx: snapshot.focusedPaneIdx
                        )
                    }
                }
                .id(tabID)
            } else {
                // Loading or error state
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }
}

// Tab layout snapshot
private struct TabLayoutSnapshot: Equatable {
    let paneIDs: [ID<WebContent>]
    let focusedPaneIdx: Int
    
    init?(tab: Tab?) {
        guard let tab else { return nil }
        self.paneIDs = tab.panes.map { $0.id }
        self.focusedPaneIdx = tab.focusedPaneIdx
    }
}

// Single pane view
private struct SinglePaneView: View {
    let paneID: ID<WebContent>
    @State private var webContent: WebContent?
    private let browserStore = BrowserStore.shared
    
    var body: some View {
        ZStack {
            // Web content
            if let webContent = webContent {
                WebView(webContent: webContent)
                    .id(webContent)
            } else {
                // Loading or error state
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
        .onAppearOrChange(of: paneID) { id in
            // Get the WebContent from BrowserStore
            webContent = browserStore.getOrCreateWebContent(forId: id)
        }
    }
}

// Split panes view
private struct SplitPanesView: View {
    let paneIDs: [ID<WebContent>]
    let focusedPaneIdx: Int
    @State private var webContentMap = [ID<WebContent>: WebContent]()
    private let browserStore = BrowserStore.shared
    
    var body: some View {
        GeometryReader { geometry in
            splitPanesContainer(geometry: geometry)
                .background(Color.gray.opacity(0.1))
        }
        .onAppear {
            loadWebContents()
        }
        .onChange(of: paneIDs) { _ in
            loadWebContents()
        }
    }
    
    // Container for all panes
    private func splitPanesContainer(geometry: GeometryProxy) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(paneIDs.enumerated()), id: \.element.id) { index, paneID in
                paneView(
                    paneID: paneID,
                    index: index,
                    width: geometry.size.width / CGFloat(paneIDs.count)
                )
            }
        }
    }
    
    // Individual pane view
    private func paneView(paneID: ID<WebContent>, index: Int, width: CGFloat) -> some View {
        ZStack {
            if let webContent = webContentMap[paneID] {
                WebView(webContent: webContent)
            } else {
                paneLoadingView
            }
        }
        .frame(width: width)
        .background(Color.white)
        .overlay(focusOverlay(index: index))
    }
    
    // Loading state for a pane
    private var paneLoadingView: some View {
        ProgressView()
    }
    
    // Focus indicator overlay
    @ViewBuilder
    private func focusOverlay(index: Int) -> some View {
        if index == focusedPaneIdx {
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.blue, lineWidth: 2)
                .opacity(0.7)
        }
    }
    
    // Load all web contents for the panes
    private func loadWebContents() {
        for paneID in paneIDs {
            if let webContent = browserStore.getOrCreateWebContent(forId: paneID) {
                webContentMap[paneID] = webContent
            }
        }
    }
}

// Empty tab view
private struct EmptyTabView: View {
    let windowID: ID<WindowState>
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "safari")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No tab selected")
                .font(.title)
                .foregroundColor(.secondary)
            
            Button("New Tab") {
                createNewTab(windowID: windowID)
            }
            .buttonStyle(TabButtonStyle())
        }
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
