import SwiftUI

struct PaneView: View {
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
                searcher: searcher,
                searchText: $searchText,
                selectedResultIndex: $selectedResultIndex,
                colorScheme: toolbarColorScheme
            )
                .shadow(color: Color.black.opacity(topbarVisible ? 0.1 : 0), radius: 5, x: 0, y: 0)
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
                WrappedWebView(webContent: webContent, isFocused: snapshot.focused, shrunk: snapshot.emptyPage)
                    .overlay(alignment: .top) {
                        loader.padding(6)
                    }
            } else {
                Color.clear
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
}
