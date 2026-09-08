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
    var isLastPane: Bool
    var makeRoomForTrafficLights: Bool
    var isEmptyPage: Bool
    var nativeKey: NativePageKey?
    /// Whether an agent hidden behind this window's omnibox is working (see
    /// BrowserState+AttachedAgents). Just a flag: the indicator observes the
    /// full status itself so its per-step detail text doesn't re-render the toolbar.
    var hasWorkingAttachedAgent: Bool
    var canOpenChat: Bool

    /// Creates a snapshot based on the browser state for a specific pane
    init(state: BrowserState, webContentId: ID<WebContent>?, windowID: ID<WindowState>?) {
        self.hasWorkingAttachedAgent = windowID.map { state.attachedAgentStatus(windowID: $0) != nil } ?? false
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
            self.isLastPane = false
            self.makeRoomForTrafficLights = false
            self.isEmptyPage = true
            self.nativeKey = nil
            canOpenChat = false
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
        self.isLastPane = tab.panes[tab.panes.count - 1]?.id == webContentId
        let isFirstPane = tab.panes.first?.id == webContentId
        let sidebarLocked = windowID != nil && state.windows[windowID!]?.sidebarLocked ?? false
        self.isEmptyPage = paneData.info.isEmptyPage
        // Display traffic lights only if top-docked (ie not empty page)
        self.makeRoomForTrafficLights = isFirstPane && !sidebarLocked && !self.isEmptyPage
        self.nativeKey = paneData.info.url.flatMap(NativePageKey.init(url:))
        self.canOpenChat = tab.panes.filter({ $0.info.isAgent }).count == 0 && !self.isEmptyPage
    }
}

/// A toolbar view that contains navigation controls and the omnibox.
/// Stateless wrt focus — the omnibox observes the FocusSnap directly.
struct ToolbarView: View {
    var webContentID: ID<WebContent>?

    @ObservedObject var searcher: Searcher
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int

    var colorScheme: ContentColorScheme?
    var emptyPage: Bool // is this being presented on an empty page?

    @Environment(\.windowID) private var windowID

    private let browserStore = BrowserStore.shared
    @ObservedObject private var devModeStore = DevModeStore.shared
    @State private var isBookmarked: Bool = false
    @State private var omniboxIsFocused: Bool = false
    /// True while a dictation session targeting this pane's omnibox is live.
    @State private var dictationTranscriptShown = false

    private func showsAttachedAgentIndicator(_ snapshot: ToolbarViewSnapshot) -> Bool {
        snapshot.hasWorkingAttachedAgent && !omniboxIsFocused && !emptyPage && !dictationTranscriptShown
    }
    @AppStorage(DefaultsKeys.hiddenTrailingToolbarItems.rawValue) private var hiddenTrailingItemsRaw = ""
    @AppStorage(DefaultsKeys.dictationButton.rawValue) private var dictationButtonEnabled = false

    private var hiddenTrailingItems: Set<ToolbarTrailingItem> {
        ToolbarTrailingItem.hiddenItems(fromRaw: hiddenTrailingItemsRaw)
    }

    var body: some View {
        let topRadius: CGFloat = emptyPage ? 10 : 0
        let bottomRadius: CGFloat = emptyPage ? 0 : (searchText == "" ? topRadius : 0) // on empty page, we show suggestions, so never round bottom corners
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

                    ZStack {
                        Omnibox(
                            paneID: webContentID,
                            searchText: omniboxIsFocused ? $searchText : Binding<String>.constant(snapshot.tabAppearance.urlFieldTextDeselected),
                            selectedResultIndex: $selectedResultIndex,
                            searcher: searcher,
                            fgColor: colorScheme?.foreground,
                            fontSize: emptyPage ? 14 : 12
                        )
                        .onAppearOrChange(of: omniboxIsFocused) { focused in
                            if focused {
                                searchText = snapshot.tabAppearance.urlFieldTextSelected
                            }
                        }
                        .opacity(showsAttachedAgentIndicator(snapshot) || dictationTranscriptShown ? 0 : 1)
                        // Hidden-agent indicator replaces the URL while an agent
                        // attached to this omnibox is working. Click to reveal.
                        if showsAttachedAgentIndicator(snapshot), let windowID {
                            AttachedAgentStatusView(windowID: windowID, fgColor: colorScheme?.foreground, fontSize: 12)
                        }
                        #if os(macOS)
                        // Live transcript while dictating into this omnibox (→ agent).
                        if dictationTranscriptShown {
                            DictationTranscriptView(fgColor: colorScheme?.foreground, fontSize: emptyPage ? 14 : 12)
                        }
                        #endif
                    }
                    .modifier(DictationOmniboxHighlightIfAvailable(paneID: webContentID, shown: $dictationTranscriptShown))
                    #if os(macOS)
                    if dictationButtonEnabled {
                        DictationButton(paneID: webContentID, emptyPage: emptyPage, fgColor: colorScheme?.foreground)
                    }
                    #endif
                }
                
                // Trailing buttons container
                if !emptyPage {
                    let hidden = hiddenTrailingItems
                    HStack(spacing: 0) {
                        if let nativeKey = snapshot.nativeKey {
                            #if os(macOS)
                            if case .fileBrowser(let path) = nativeKey, let path, !path.isEmpty {
                                FileBrowserToolbarItems(path: path, nativeKey: nativeKey, openInOtherType: openNativeTabInOtherType)
                            } else {
                                OpenInOtherNativeMenu(currentKey: nativeKey, openInOtherType: openNativeTabInOtherType)
                            }
                            #endif
                        } else if let webContentID, !hidden.contains(.cleanMode) {
                            CleanModeStatusButton(webContentID: webContentID)
                        }

                        #if os(macOS)
                        // Webapp "tab" entry points (hidden when none installed)
                        if let webContentID, snapshot.nativeKey == nil, !hidden.contains(.extensions) {
                            TabExtensionsMenuButton(webContentID: webContentID, url: snapshot.url)
                        }
                        #endif
                                            
                        // Dev mode's one extra control: mobile viewport on/off.
                        if !hidden.contains(.mobileViewport), let devDomain = devModeDomain(snapshot: snapshot), devModeStore.isEnabled(for: devDomain) {
                            let mobile = devModeStore.config(for: devDomain).mobile
                            Button(action: { devModeStore.modify(devDomain) { $0.mobile.toggle() } }) {
                                Image(systemName: mobile ? "iphone.gen3" : "iphone.gen3.slash")
                                    .imageScale(.medium)
                            }
                            .buttonStyle(ToolbarButtonStyle())
                            .help(mobile ? "Turn off mobile viewport" : "Turn on mobile viewport")
                        }

                        if !hidden.contains(.bookmark) {
                            Button(action: toggleBookmark) {
                                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                                    .imageScale(.medium)
                                    .help(isBookmarked ? "Remove Bookmark (⇧⌘D)" : "Add Bookmark (⇧⌘D)")
                            }
                            .buttonStyle(ToolbarButtonStyle())
                            .disabled(snapshot.url == nil)
                            .onReceive(ArchiveStore.shared.publisher.map({ $0.isBookmarked(url: snapshot.url) }).removeDuplicates().receive(on: DispatchQueue.main), perform: { self.isBookmarked = $0 })
                        }
                        
                        if snapshot.canOpenChat, !hidden.contains(.openChat) {
                            Button(action: openChatSplit) {
                                Image(systemName: "bubble.left")
                                    .imageScale(.medium)
                            }
                            .buttonStyle(ToolbarButtonStyle())
                            .help("Open chat in split view")
                        }
                        
                        // Close pane button (only visible in split view)
                        if snapshot.hasMultiplePanes, !hidden.contains(.closePane) {
                            Button(action: closeCurrentPane) {
                                Image(systemName: "xmark")
                                    .imageScale(.medium)
                            }
                            .buttonStyle(ToolbarButtonStyle())
                            .help("Close pane")
                        }

                        // New split pane button (only on the last pane)
                        if snapshot.isLastPane, !hidden.contains(.newSplitPane) {
                            Button(action: addSplitPane) {
                                Image(systemName: "plus")
                                    .imageScale(.medium)
                            }
                            .buttonStyle(ToolbarButtonStyle())
                            .help("New split pane")
                        }

//                        // Always-present grab area so the customization menu is reachable even when every button is hidden.
//                        Color.clear.frame(width: 8, height: UIConstants.macHeaderHeight)
                    }
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                    .contextMenu {
                        ForEach(ToolbarTrailingItem.Group.allCases, id: \.self) { group in
                            Section(group.title) {
                                ToolbarTrailingItemToggles(items: group.items)
                            }
                        }
                        Divider()
                        Button("Customize Toolbar…") { SettingsTab.toolbar.open() }
                    }
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

                if let devDomain = devModeDomain(snapshot: snapshot) {
                    Toggle(isOn: Binding(
                        get: { devModeStore.isEnabled(for: devDomain) },
                        set: { devModeStore.setEnabled($0, for: devDomain) }
                    )) {
                        Text("Dev Mode")
                    }
                }

//                Toggle(isOn: $topbarLocked) {
//                    Text("Lock Toolbar")
//                }
            }
        }
        .onReceiveFocusSnap(windowID: windowID) { snap in
            // Used only to swap the omnibox text binding between live-edit and the
            // tab's deselected URL/title display. Focus itself is handled by Omnibox.
            if let webContentID, snap.target == .omnibox(pane: webContentID) {
                omniboxIsFocused = true
            } else if webContentID == nil, let windowID, snap.target == .emptyWindowOmnibox(windowID) {
                omniboxIsFocused = true
            } else {
                omniboxIsFocused = false
            }
        }
        .modifier(WithContentColorScheme(scheme: colorScheme, hideBg: emptyPage))
        .clipShape(clipShape)
//        .overlay {
//            if emptyPage {
//                clipShape.strokeBorder(Color.primary)
//                    .padding(-1)
//                    .opacity(0.1)
//            }
//        }
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
            .help("Back (⌘[)")

            // Forward button
            Button(action: goForward) {
                Image(systemName: "chevron.forward")
                    .imageScale(.medium)
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(!snapshot.canGoForward)
            .help("Forward (⌘])")

            if case .fileBrowser(let path) = snapshot.nativeKey {
                let parent = fileBrowserParentPath(path)
                Button(action: { fileBrowserGoUp(currentPath: path) }) {
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
                .help("Reload (⌘R)")
            }
        }
    }
    
    func openChatSplit() {
        if let windowID {
            AgentChatTabs.openChatSplit(windowID: windowID)
        }
    }

    /// The dev-mode domain for this pane, or nil where dev mode doesn't apply
    /// (native pages like the VS Code / terminal tabs, empty pages, non-http URLs).
    private func devModeDomain(snapshot: ToolbarViewSnapshot) -> String? {
        guard snapshot.nativeKey == nil, !snapshot.isEmptyPage else { return nil }
        return DevModeStore.domain(for: snapshot.url)
    }

    private func openNativeTabInOtherType(_ key: NativePageKey) {
        BrowserStore.shared.modify { state in
            state.openTab(url: key.url, windowID: windowID)
        }
    }

    private func fileBrowserParentPath(_ path: String?) -> String? {
        #if os(macOS)
        let resolved: String = {
            if let path, !path.isEmpty {
                return (path as NSString).expandingTildeInPath
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }()
        if resolved == "/" || resolved.isEmpty { return nil }
        let parent = (resolved as NSString).deletingLastPathComponent
        return parent == resolved ? nil : parent
        #else
        return nil
        #endif
    }

    private func fileBrowserGoUp(currentPath: String?) {
        guard let parent = fileBrowserParentPath(currentPath),
              let webContentID,
              let webContent = browserStore.getOrCreateWebContent(forId: webContentID, toBeActiveInWindow: windowID!) else {
            return
        }
        let key = NativePageKey.fileBrowser(path: parent)
        webContent.load(request: URLRequest(url: key.url))
    }
    
    // MARK: - Actions

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
        webContent.reload()
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

    private func addSplitPane() {
        guard let windowID else { return }
        browserStore.createTab(withURL: nil, in: windowID, activate: true, inCurrentSplit: true)
    }
}

// Style for toolbar buttons with consistent appearance
#if os(macOS)
/// File-browser toolbar cluster: reveal/open always; the "open this folder
/// in…" menu only while viewing a folder (it's meaningless for a single file).
/// Folder-vs-file is checked on disk here in the view layer, once per path.
struct FileBrowserToolbarItems: View {
    var path: String
    var nativeKey: NativePageKey
    var openInOtherType: (NativePageKey) -> Void

    @State private var isDirectory = true

    var body: some View {
        FileRevealAndOpenButtons(path: path)
        if isDirectory {
            OpenInOtherNativeMenu(currentKey: nativeKey, openInOtherType: openInOtherType)
        }
        Color.clear.frame(width: 0, height: 0)
            .onAppearOrChange(of: path) { path in
                let expanded = (path as NSString).expandingTildeInPath
                DispatchQueue.global(qos: .userInitiated).async {
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
                    let result = !exists || isDir.boolValue
                    DispatchQueue.main.async { isDirectory = result }
                }
            }
    }
}

/// "Reveal in Finder" + "Open in Default App" for the file-browser toolbar.
struct FileRevealAndOpenButtons: View {
    var path: String

    private var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    var body: some View {
        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
            RevealInFinderGlyph()
        }
        .buttonStyle(ToolbarButtonStyle())
        .help("Reveal in Finder")

        Button(action: { NSWorkspace.shared.open(url) }) {
            Image(systemName: "arrow.up.forward.app")
                .imageScale(.medium)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help("Open in Default App")
    }
}

/// Folder with a small outward arrow badge (SF Symbols has no such glyph).
struct RevealInFinderGlyph: View {
    var body: some View {
        Image(systemName: "folder")
            .imageScale(.medium)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .heavy))
                    .padding(1)
                    .background(Circle().fill(.background))
                    .offset(x: 3, y: 2)
            }
    }
}
#endif

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

extension WebContent.Info {
    var isAgent: Bool {
        if let url = committedURL ?? url, let native = NativePageKey(url: url) {
            return native.isAgent
        }
        return false
    }
}
