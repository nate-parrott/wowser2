import SwiftUI

/// A snapshot containing minimal data needed for the toolbar
public struct ToolbarViewSnapshot: Equatable {
    var url: URL?
    var tabAppearance: TabAppearance
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var isSecure: Bool
    var webContentId: ID<WebContent>?
//    var isBookmarked: Bool
    var hasMultiplePanes: Bool
    var makeRoomForTrafficLights: Bool
    var isEmptyPage: Bool
    var nativeKey: NativePageKey?

    /// Creates a snapshot based on the browser state for a specific pane
    init(state: BrowserState, webContentId: ID<WebContent>?, windowID: ID<WindowState>?) {
        guard let webContentId,
              let tabId = state.paneToTabMapping[webContentId],
              let tab = state.tabs[tabId],
              let paneData = tab.panes.first(where: { $0.id == webContentId }) else {
            self.url = nil
            self.tabAppearance = .empty
            self.isLoading = false
            self.canGoBack = false
            self.canGoForward = false
            self.isSecure = false
            self.webContentId = webContentId
//            self.isBookmarked = false
            self.hasMultiplePanes = false
            self.makeRoomForTrafficLights = false
            self.isEmptyPage = true
            self.nativeKey = nil
            return
        }

        self.url = paneData.info.url
        self.tabAppearance = paneData.tabAppearance()
        self.isLoading = paneData.info.isLoading
        self.canGoBack = paneData.info.canGoBack
        self.canGoForward = paneData.info.canGoForward
        self.isSecure = paneData.info.isSecure
        self.webContentId = webContentId
//        self.isBookmarked = false // Bookmark functionality not implemented yet
        self.hasMultiplePanes = tab.panes.count > 1
        let isFirstPane = tab.panes.first?.id == webContentId
        let sidebarLocked = windowID != nil && state.windows[windowID!]?.sidebarLocked ?? false
        self.makeRoomForTrafficLights = isFirstPane && !sidebarLocked
        self.isEmptyPage = paneData.info.isEmptyPage
        self.nativeKey = paneData.info.url.flatMap(NativePageKey.init(url:))
    }
}

/// A toolbar view that contains navigation controls and the omnibox
public struct ToolbarView: View {
    var searchFocused: Bool
    var paneFocused: Bool
    var webContentID: ID<WebContent>?

    @ObservedObject var searcher: Searcher
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int

    var colorScheme: ContentColorScheme?
    var emptyPage: Bool // is this being presented on an empty page?

    @Environment(\.windowID) private var windowID
//    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false

    private let browserStore = BrowserStore.shared
    @State private var focusDate: Date?
    @State private var isBookmarked: Bool = false
    @State private var lastBecameKeyAt: Date?

//    private struct OmniboxFocusSnap: Equatable {
//        var searchFocused: Bool
//        var paneFocused: Bool
//        var emptyPage: Bool
//        var lastBecameKeyAt: Date?
//    }
    private var omniboxFocusSnap: OmniboxFocusSnap {
        OmniboxFocusSnap(searchFocused: searchFocused, paneFocused: paneFocused, emptyPage: emptyPage, lastBecameKeyAt: lastBecameKeyAt)
    }
    
    private var omniboxFocusDate: Date? {
        if searchFocused && paneFocused
    }
    
    public var body: some View {
        let topRadius: CGFloat = emptyPage ? 10 : 0
        let bottomRadius: CGFloat = searchText == "" ? topRadius : 0
        let clipShape = UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius, style: .continuous)
        
        WithSnapshotMain(store: browserStore, snapshot: { ToolbarViewSnapshot(state: $0, webContentId: webContentID, windowID: windowID) }) { snapshot in
            HStack(spacing: 4) {
                if snapshot.makeRoomForTrafficLights {
                    MacWindowControlsIfValidElse(leftPadding: 12) {
                        EmptyView()
                    }
                }
                
                // Leading nav controls
                if !emptyPage {
                    navControls(snapshot: snapshot)
                        .padding(.leading, 4)
                }
                
                // Security indicator and Omnibox (search/URL input field)
                HStack(spacing: -2) {
                    if snapshot.nativeKey == nil {
                        LeadingIcon(isSecure: snapshot.url != nil ? snapshot.isSecure : nil, iconOverride: snapshot.isEmptyPage ? "magnifyingglass" : nil)
                            .padding(.leading, 6)
                    }

                    Omnibox(
                        focusDate: focusDate,
                        searchText: searchFocused ? $searchText : Binding<String>.constant(snapshot.tabAppearance.urlFieldTextDeselected),
                        selectedResultIndex: $selectedResultIndex,
                        searcher: searcher,
                        fgColor: colorScheme?.foreground,
                        onFocus: activateSearchOverlay,
                        fontSize: emptyPage ? 14 : 12
                    )
//                    .border(searchFocused ? Color.red : Color.clear)
                }
                
                // Trailing buttons container
                if !emptyPage {
                    HStack(spacing: 0) {
                        if let nativeKey = snapshot.nativeKey {
                            OpenInOtherNativeMenu(currentKey: nativeKey, openInOtherType: openNativeTabInOtherType)
                        } else if let webContentID {
                            CleanModeStatusButton(webContentID: webContentID)
//                                .tint(colorScheme?.foreground.color ?? Color.primary)
//                                .padding(.trailing)
                        }
                                            
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
                    .padding(.trailing, 8)
                }
            }
            .frame(height: UIConstants.macHeaderHeight)
            .contentShape(Rectangle())
            .contextMenu {
                Button(action: {
                    copyURLToClipboard(url: snapshot.url)
                }) {
                    Text("Copy URL")
                }
                
//                Toggle(isOn: $topbarLocked) {
//                    Text("Lock Toolbar")
//                }
            }
        }
        .onAppearOrChange(of: omniboxFocusSnap) { snap in
            if snap.searchFocused {
                focusDate = Date()
            } else if snap.paneFocused && snap.emptyPage {
                // Activate the overlay; the resulting state change re-fires
                // this with searchFocused=true, which sets focusDate.
                activateSearchOverlay()
            } else {
                focusDate = nil
            }
        }
        .onReceive(BrowserStore.shared.uiPublisher.map { state -> Date? in
            guard let windowID else { return nil }
            return state.windows[windowID]?.lastBecameKeyAt
        }.removeDuplicates()) { self.lastBecameKeyAt = $0 }
        .modifier(WithContentColorScheme(scheme: colorScheme))
        .clipShape(clipShape)
        .overlay {
            if emptyPage {
                clipShape.strokeBorder(Color.primary)
                    .padding(-1)
                    .opacity(0.1)
            }
        }
        .compositingGroup()
        .animation(.niceDefault, value: colorScheme)
        .id(webContentID)
    }
    
    @ViewBuilder private func navControls(snapshot: ToolbarViewSnapshot) -> some View {
        HStack(spacing: 0) {
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

            if case .fileBrowser(let id, let path) = snapshot.nativeKey {
                let parent = fileBrowserParentPath(path)
                Button(action: { fileBrowserGoUp(sessionID: id, currentPath: path) }) {
                    Image(systemName: "chevron.up")
                        .imageScale(.medium)
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(parent == nil)
                .help("Up one folder")
            } else {
                // Reload button
                Button(action: reload) {
                    Image(systemName: snapshot.isLoading ? "xmark" : "arrow.clockwise")
                        .imageScale(.medium)
                }
                .buttonStyle(ToolbarButtonStyle())
            }
        }
    }

    private func openNativeTabInOtherType(_ key: NativePageKey) {
        BrowserStore.shared.modify { state in
            state.openTab(url: key.url, windowID: windowID)
        }
    }

    private func fileBrowserParentPath(_ path: String?) -> String? {
        let resolved: String = {
            if let path, !path.isEmpty {
                return (path as NSString).expandingTildeInPath
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }()
        if resolved == "/" || resolved.isEmpty { return nil }
        let parent = (resolved as NSString).deletingLastPathComponent
        return parent == resolved ? nil : parent
    }

    private func fileBrowserGoUp(sessionID: String, currentPath: String?) {
        guard let parent = fileBrowserParentPath(currentPath),
              let webContentID,
              let webContent = browserStore.getOrCreateWebContent(forId: webContentID, toBeActiveInWindow: windowID!) else {
            return
        }
        let key = NativePageKey.fileBrowser(id: sessionID, path: parent)
        webContent.webview.load(URLRequest(url: key.url))
    }
    
    // MARK: - Actions
    
    private func activateSearchOverlay() {
        if let webContentID {
            searchText = browserStore.model.pane(forId: webContentID)?.tabAppearance().urlFieldTextSelected ?? "" // .url?.absoluteString ?? ""
        }
        browserStore.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = true
            }
            if let webContentID {
                state.makePaneActive(webContentID: webContentID)
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
        guard let webContentID else { return }
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
            .font(.system(size: 13, weight: .medium))
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

private struct LeadingIcon: View {
    var isSecure: Bool?
    var iconOverride: String?
    
    var body: some View {
        Button(action: {}) {
            if let iconOverride {
                Image(systemName: iconOverride)
                    .opacity(0.33)
            } else if let isSecure {
                Image(systemName: isSecure ? "lock.fill" : "lock.open.fill")
                    .opacity(0.33)
            } else {
                Image(systemName: "square.fill")
                    .opacity(0.1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .help(isSecure != nil ? (isSecure! ? "Site is secure" : "Site is not entirely secure") : "")
        .accessibilityHidden(isSecure == nil)
        .buttonStyle(ToolbarButtonStyle())
        .padding(.trailing, -8)
    }
}
