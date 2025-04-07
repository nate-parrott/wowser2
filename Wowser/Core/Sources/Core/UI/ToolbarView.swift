import SwiftUI

/// A snapshot containing minimal data needed for the toolbar
public struct ToolbarViewSnapshot: Equatable {
    var url: URL?
    var title: String?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var webContentId: ID<WebContent>?
//    var isBookmarked: Bool
    var hasMultiplePanes: Bool
    var makeRoomForTrafficLights: Bool
    
    /// Creates a snapshot based on the browser state for a specific pane
    init(state: BrowserState, webContentId: ID<WebContent>?, windowID: ID<WindowState>?) {
        guard let webContentId,
              let tabId = state.paneToTabMapping[webContentId],
              let tab = state.tabs[tabId],
              let paneData = tab.panes.first(where: { $0.id == webContentId }) else {
            self.url = nil
            self.title = nil
            self.isLoading = false
            self.canGoBack = false
            self.canGoForward = false
            self.webContentId = webContentId
//            self.isBookmarked = false
            self.hasMultiplePanes = false
            self.makeRoomForTrafficLights = false
            return
        }
        
        self.url = paneData.info.url
        self.title = paneData.info.title
        self.isLoading = paneData.info.isLoading
        self.canGoBack = paneData.info.canGoBack
        self.canGoForward = paneData.info.canGoForward
        self.webContentId = webContentId
//        self.isBookmarked = false // Bookmark functionality not implemented yet
        self.hasMultiplePanes = tab.panes.count > 1
        let isFirstPane = tab.panes.first?.id == webContentId
        let sidebarLocked = windowID != nil && state.windows[windowID!]?.sidebarLocked ?? false
        self.makeRoomForTrafficLights = isFirstPane && !sidebarLocked
    }
}

/// A toolbar view that contains navigation controls and the omnibox
public struct ToolbarView: View {
    var searchFocused: Bool
    var webContentID: ID<WebContent>?
    var fgColor: HSBA?
    
    @ObservedObject var searcher: Searcher
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int
    
    @Environment(\.windowID) private var windowID
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    
    private let browserStore = BrowserStore.shared
    @State private var focusDate: Date?
    @State private var isBookmarked: Bool = false
    
    public var body: some View {
        WithSnapshotMain(store: browserStore, snapshot: { ToolbarViewSnapshot(state: $0, webContentId: webContentID, windowID: windowID) }) { snapshot in
            HStack(spacing: 8) {
                if snapshot.makeRoomForTrafficLights {
                    Spacer().frame(width: 60)
                }
                // Omnibox (search/URL input field)
                Omnibox(
                    focusDate: focusDate,
                    searchText: searchFocused ? $searchText : Binding<String>.constant(snapshot.url?.hostWithoutWWW ?? ""),
                    selectedResultIndex: $selectedResultIndex,
                    searcher: searcher,
                    fgColor: fgColor,
                    onFocus: activateSearchOverlay
                )
                
                // Trailing buttons container
                HStack(spacing: 8) {
                    // Back button
                    Button(action: goBack) {
                        Image(systemName: "chevron.backward")
                            .imageScale(.medium)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .disabled(!snapshot.canGoBack)
                    
                    // Forward button
                    Button(action: goForward) {
                        Image(systemName: "chevron.forward")
                            .imageScale(.medium)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .disabled(!snapshot.canGoForward)
                    
                    // Reload button
                    Button(action: reload) {
                        Image(systemName: snapshot.isLoading ? "xmark" : "arrow.clockwise")
                            .imageScale(.medium)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    
                    Button(action: toggleBookmark) {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .imageScale(.medium)
                            .help(isBookmarked ? "Remove Bookmark" : "Add Bookmark")
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .disabled(snapshot.url == nil)
                    .onReceive(ArchiveStore.shared.publisher.map({ $0.isBookmarked(url: snapshot.url) }).removeDuplicates().receive(on: DispatchQueue.main), perform: { self.isBookmarked = $0 })
                    
                    // Close pane button (only visible in split view)
                    if snapshot.hasMultiplePanes {
                        Button(action: closeCurrentPane) {
                            Image(systemName: "xmark")
                                .imageScale(.medium)
                        }
                        .buttonStyle(ToolbarButtonStyle())
                        .help("Close pane")
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button(action: {
                        copyURLToClipboard(url: snapshot.url)
                    }) {
                        Text("Copy URL")
                    }
                    
                    Toggle(isOn: $topbarLocked) {
                        Text("Lock Toolbar")
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: UIConstants.macHeaderHeight)
//            .overlay(alignment: .bottom) {
//                (fgColor?.color ?? Color.primary).frame(height: 1).opacity(0.1)
//            }
        }
        .onAppearOrChange(of: searchFocused, perform: { focused in
            focusDate = focused ? Date() : nil
        })
        .id(webContentID)
    }
    
    // MARK: - Actions
    
    private func activateSearchOverlay() {
        if let webContentID {
            searchText = browserStore.model.tabInfo(forWebContentId: webContentID)?.url?.absoluteString ?? ""
        }
        browserStore.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = true
            }
        }
    }
    
    private func goBack() {
        guard let webContentID,
              let webContent = browserStore.getOrCreateWebContent(forId: webContentID, toBeActiveInWindow: windowID!) else {
            return
        }
        webContent.goBack()
    }
    
    private func goForward() {
        guard let webContentID,
              let webContent = browserStore.getOrCreateWebContent(forId: webContentID, toBeActiveInWindow: windowID!) else {
            return
        }
        webContent.goForward()
    }
    
    private func reload() {
        guard let webContentID,
              let webContent = browserStore.getOrCreateWebContent(forId: webContentID, toBeActiveInWindow: windowID!) else {
            return
        }
        webContent.webview.reload()
    }
    
    private func toggleBookmark() {
        guard let webContentID else { return }
        guard let tabInfo = browserStore.model.tabInfo(forWebContentId: webContentID) else { return }
        ArchiveStore.shared.toggleBookmark(url: tabInfo.url, title: tabInfo.title)
    }
    
    private func closeCurrentPane() {
        guard let webContentID, let windowID else { return }
        
        // Close the current pane using BrowserStore
        browserStore.close(webContentId: webContentID, removeIfPinned: false)
    }
}

// Style for toolbar buttons with consistent appearance
struct ToolbarButtonStyle: ButtonStyle {
    @State private var hovered = false
    
    @Environment(\.isEnabled) private var enabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.33)
            .frame(width: 30, height: 30)
            .background {
                if hovered && enabled {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary)
                        .opacity(configuration.isPressed ? 0.1 : (hovered ? 0.07 : 0))
                }
            }
            .onHover(perform: { self.hovered = $0 })
    }
}

extension BrowserState {
    func tabInfo(forWebContentId id: ID<WebContent>) -> WebContent.Info? {
        if let tabId = paneToTabMapping[id], let tab = tabs[tabId] {
            return tab.panes.first(where: { $0.id == id })?.info
        }
        return nil
    }
}

extension ArchiveState {
    func isBookmarked(url: URL?) -> Bool {
        if let url {
            return itemsByHistoryKey[url.historyKey]?.kind == .bookmark
        }
        return false
    }
}
