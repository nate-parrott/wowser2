import SwiftUI

/// A snapshot containing minimal data needed for the toolbar
public struct ToolbarViewSnapshot: Equatable {
    var url: URL?
    var title: String?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var webContentId: ID<WebContent>?
    var isBookmarked: Bool
    var hasMultiplePanes: Bool
    
    /// Creates a snapshot based on the browser state for a specific pane
    init(state: BrowserState, webContentId: ID<WebContent>?) {
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
            self.isBookmarked = false
            self.hasMultiplePanes = false
            return
        }
        
        self.url = paneData.info.url
        self.title = paneData.info.title
        self.isLoading = paneData.info.isLoading
        self.canGoBack = paneData.info.canGoBack
        self.canGoForward = paneData.info.canGoForward
        self.webContentId = webContentId
        self.isBookmarked = false // Bookmark functionality not implemented yet
        self.hasMultiplePanes = tab.panes.count > 1
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
    
    private let browserStore = BrowserStore.shared
    @State private var focusDate: Date?
    
    public var body: some View {
        WithSnapshotMain(store: browserStore, snapshot: { ToolbarViewSnapshot(state: $0, webContentId: webContentID) }) { snapshot in
            HStack(spacing: 8) {
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
                    
                    // Bookmark button (not implemented)
                    Button(action: toggleBookmark) {
                        Image(systemName: snapshot.isBookmarked ? "bookmark.fill" : "bookmark")
                            .imageScale(.medium)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    
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
        // Bookmark functionality not implemented yet
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
