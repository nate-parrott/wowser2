import SwiftUI
import Combine

struct PaneView: View {
    var snapshot: WindowSnapshot.PaneSnapshot
    var singlePane: Bool
    var topbarVisible: Bool
    var toolbarColorScheme: ContentColorScheme?
    /// Don't mount the toolbar at all (pip panels). `topbarVisible: false`
    /// only offsets it up offscreen, which leaves it hit-testable.
    var toolbarHidden = false

    @State private var searchText: String = ""
    @State private var selectedResultIndex = 0

    @Environment(\.windowID) private var windowID
    // Create Searcher with profile-specific history store
    @StateObject private var searcher = Searcher()
    @StateObject private var topSitesFetcher = TopSitesFetcher()
    @Environment(\.profileID) private var profileID
//    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var size: CGSize = .zero
    
    /// Assumed max height of the empty-page search UI (input box + fully
    /// populated results list). We vertically center a box of this height and
    /// top-align the search UI within it, so the input stays put as results
    /// appear/disappear instead of re-centering on every keystroke.
    /// Derivation: 42 (macHeaderHeight input bar) + 10×2 (results stack
    /// padding) + 6 (Searcher max results) × ~34pt rows ≈ 274.
    private static let emptySearchUIMaxHeight: CGFloat = 274

    var body: some View {
        let emptyPageSearchPadding: CGFloat = snapshot.emptyPage ? (size.width > 700 && size.height > 600 ? 120 : 50) : 0
        let emptyPageTopPadding: CGFloat = snapshot.emptyPage ? max(emptyPageSearchPadding, (size.height - Self.emptySearchUIMaxHeight) / 2) : 0
        let topbarLocked = snapshot.topbarLocked

        ZStack(alignment: .top) {
            content
                .padding(.top, topbarLocked ? UIConstants.macHeaderHeight : 0)
                .scaleEffect(y: !topbarLocked && topbarVisible ? (size.height - UIConstants.macHeaderHeight) / max(size.height, 1) : 1, anchor: .bottom)
//                .opacity(snapshot.searchActive ? 0.1 : 1)
            
            if snapshot.searchActive {
                SearchResultsOverlay(
                    searchText: $searchText,
                    selectedResultIndex: $selectedResultIndex,
                    searcher: searcher,
                    drawsCenteredBackdropIncludingBehindToolbar: snapshot.emptyPage // in empty-page centered mode, we draw our own backdrop in a parent
                )
                    // Dictation-to-agent outline around the whole new-tab card
                    // (backdrop + toolbar). Drawn here when results are showing;
                    // otherwise the toolbar's own highlight covers the card.
                    .environment(\.dictationHighlightPaneID, snapshot.webContentId)
                    .padding(.top, UIConstants.macHeaderHeight)
                    .padding(.horizontal, emptyPageSearchPadding)
                    .padding(.top, emptyPageTopPadding)
            }
            
            if !toolbarHidden {
                ToolbarView(
                    webContentID: snapshot.webContentId,
                    searcher: searcher,
                    searchText: $searchText,
                    selectedResultIndex: $selectedResultIndex,
                    colorScheme: toolbarColorScheme,
                    emptyPage: snapshot.emptyPage
                )
                .overlay(alignment: .bottom) {
                    if !snapshot.emptyPage {
                        (toolbarColorScheme?.foreground.color ?? Color.black).opacity(0.1)
                            .frame(height: 1)
                    }
                }
//            .blur(radius: !topbarVisible ? 5 : 0)
                .shadow(color: Color.black.opacity(topbarVisible && snapshot.emptyPage ? 0.1 : 0), radius: snapshot.emptyPage ? 12 : 0, x: 0, y: 0)
                    .modifier(DictationCardHighlightIfAvailable(
                        paneID: snapshot.webContentId,
                        cornerRadius: snapshot.emptyPage ? 10 : 0,
                        // With results showing on the new-tab page, the results
                        // overlay outlines the full card instead.
                        enabled: !(snapshot.emptyPage && snapshot.searchActive && !searcher.results.isEmpty)
                    ))
                    .offset(y: topbarVisible ? 0 : -UIConstants.macHeaderHeight)
                    .padding(.horizontal, emptyPageSearchPadding)
                    .padding(.top, emptyPageTopPadding)
                    .id(snapshot.emptyPage)
//                .scaleEffect(y: topbarVisible ? 1 : 0.0001, anchor: .top)
            }
                        
            if snapshot.emptyPage, !singlePane {
                closeButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
        }
        .animation(.niceDefault, value: snapshot.emptyPage)
//        .modifier(ToastFirstTimeCleanModeAutoActivates(paneID: snapshot.webContentId))
        .measureSize { self.size = $0 }
        .overlay(alignment: .bottom) {
            if snapshot.focused, !singlePane {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(profileDataStoreID, perform: { id in
            searcher.datastoreProfileID = id
            topSitesFetcher.profileDataStoreID = id
        })
        .onAppearOrChange(of: windowID, perform: { windowID in
            searcher.windowID = windowID
        })
        .onAppearOrChange(of: snapshot.emptyPage, perform: { emptyPage in
            searcher.topSitesEnabled = emptyPage
        })
        .onReceive(topSitesFetcher.$topSites, perform: { sites in
            searcher.topSites = sites
        })
        .onChange(of: searchText) { newValue in
            searcher.query = newValue
            selectedResultIndex = 0 // Reset selection when query changes
        }
        .onChange(of: snapshot.searchActive) {
            if $0 {
                searcher.refreshForEmptyQuery()
            } else {
                searchText = ""
            }
        }
        .animation(nil, value: snapshot.topbarLocked) // supress animation when changing sidebar locking (which is also not animated)
        .animation(.niceDefault(duration: 0.12), value: topbarVisible)
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
    
    @ViewBuilder private var elementPicker: some View {
        if let mode = snapshot.selectorPickerMode,
           let webContentId = snapshot.webContentId,
           let windowID = windowID,
           let webContent = BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID) {
            ElementPickerOverlay(webContent: webContent, mode: mode) { selector in
                if let selector = selector {
                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(selector, forType: .string)
                    #endif

                    // Show a toast
                    BrowserStore.shared.modify { state in
                        let toast = Toast(
                            message: "Copied selector to clipboard",
                            icon: "doc.on.clipboard"
                        )
                        state.windows[windowID]?.toasts.append(toast)
                        state.windows[windowID]?.selectorPicker = nil
                    }
                } else {
                    // User cancelled
                    BrowserStore.shared.modify { state in
                        state.windows[windowID]?.selectorPicker = nil
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            // Search toolbar appears at the top when applicable
            SearchToolbarIfNeeded(
                webContentId: snapshot.webContentId,
                colorScheme: toolbarColorScheme
            )
            
            // Main web content
            ZStack {
                if let webContentId = snapshot.webContentId, let windowID, let webContent = BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID) {
                    DevModeMobileContainer(webContent: webContent) {
                        WrappedWebView(webContent: webContent, shrunk: snapshot.emptyPage)
                            .overlay(alignment: .top) {
                                loader.padding(6)
                            }
                            .overlay {
                                elementPicker
                            }
                    }
                } else {
                    Color.clear
                }
            }
        }
    }
    
    @ViewBuilder private var loader: some View {
        if let webContentId = snapshot.webContentId, !snapshot.emptyPage {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.loadingProgress(webContentId: webContentId) }) { prog in
                LoadingIndicator(progress: prog == 1 ? nil : prog)
            }
        }
    }
    
    // Used for split-pane New Tab Pages (empty pages) where the toolbar doesn't contain the x
    @ViewBuilder private var closeButton: some View {
        // Must show an x icon on empty pages
        Button(action: {
            // Close current pane
            guard let webContentID = snapshot.webContentId else { return }
            BrowserStore.shared.close(webContentId: webContentID, removeIfPinned: false)
        }) {
            Image(systemName: "xmark")
                .imageScale(.medium)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help("Close Pane")
    }
}
