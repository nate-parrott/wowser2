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

    @Environment(\.windowID) private var windowID
    /// Links the omnibox field and its suggestions (see OmniboxCoordinator).
    @StateObject private var omnibox = OmniboxCoordinator()
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
        if snapshot.blank {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fullBody
        }
    }

    @ViewBuilder private var fullBody: some View {
        let emptyPageSearchPadding: CGFloat = snapshot.emptyPage ? (size.width > 700 && size.height > 600 ? 120 : 50) : 0
        let emptyPageTopPadding: CGFloat = snapshot.emptyPage ? max(emptyPageSearchPadding, (size.height - Self.emptySearchUIMaxHeight) / 2) : 0
        let topbarLocked = snapshot.topbarLocked

        ZStack(alignment: .top) {
            content
                .padding(.top, topbarLocked ? UIConstants.macHeaderHeight : 0)
                .scaleEffect(y: !topbarLocked && topbarVisible ? (size.height - UIConstants.macHeaderHeight) / max(size.height, 1) : 1, anchor: .bottom)

            if snapshot.searchActive {
                // Click outside the command bar to close it.
                Color.white.opacity(0.01)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { omnibox.dismiss() }
            }

            if snapshot.emptyPage {
                if !toolbarHidden {
                    NewTabCommandBar(paneID: snapshot.webContentId, coordinator: omnibox)
                        .padding(.horizontal, emptyPageSearchPadding)
                        .padding(.top, emptyPageTopPadding)
                }
            } else {
                if snapshot.searchActive {
                    OmniboxDropdown(coordinator: omnibox)
                        .padding(.top, UIConstants.macHeaderHeight)
                }
                if !toolbarHidden {
                    ToolbarView(
                        webContentID: snapshot.webContentId,
                        coordinator: omnibox,
                        colorScheme: toolbarColorScheme
                    )
                    .overlay(alignment: .bottom) {
                        (toolbarColorScheme?.foreground.color ?? Color.black).opacity(0.1)
                            .frame(height: 1)
                    }
                    .modifier(DictationCardHighlightIfAvailable(paneID: snapshot.webContentId, cornerRadius: 0))
                    .offset(y: topbarVisible ? 0 : -UIConstants.macHeaderHeight)
                }
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
            omnibox.searcher.datastoreProfileID = id
            topSitesFetcher.profileDataStoreID = id
        })
        .onAppearOrChange(of: windowID) { omnibox.windowID = $0 }
        .onAppearOrChange(of: snapshot.webContentId) { omnibox.paneID = $0 }
        .onAppearOrChange(of: snapshot.emptyPage) { omnibox.searcher.topSitesEnabled = $0 }
        .onReceive(topSitesFetcher.$topSites) { omnibox.searcher.topSites = $0 }
        .onAppearOrChange(of: snapshot.searchActive) { active in
            omnibox.paneID = snapshot.webContentId // seeding reads it; don't depend on handler order
            omnibox.setActive(active)
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
