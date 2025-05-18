import SwiftUI

public struct MobileContentView: View {
    public var windowID: ID<WindowState>
        
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { MobileContentSnapshot(state: $0, windowID: windowID) }) { snapshot in
            _MobileContentView(snapshot: snapshot)
                .environment(\.profileID, snapshot.profileID)
        }
        .environment(\.windowID, windowID)
    }
}

private struct _MobileContentView: View {
    var snapshot: MobileContentSnapshot
    @Environment(\.windowID) private var windowID
    
    var body: some View {
        ZStack {
            webContent

            SearchOrb()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(30)

            if snapshot.searchActive {
                MobileSearchOverlay()
            }
        }
        .background {
            Group {
                snapshot.windowBgColor?.color
            }
            .ignoresSafeArea()
        }
    }
    
    @ViewBuilder private var webContent: some View {
        let focused = !snapshot.searchActive
        if let paneID = snapshot.currentPane, let windowID, let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: windowID) {
            WrappedWebView(webContent: webContent, isFocused: focused, shrunk: snapshot.isEmptyPage)
                .overlay(alignment: .top) {
                    loader.padding(6)
                }
                .edgesIgnoringSafeArea(.bottom)
        } else {
            Color.clear
        }
    }
    
    @ViewBuilder private var loader: some View {
        if let webContentId = snapshot.currentPane, !snapshot.isEmptyPage {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.loadingProgress(webContentId: webContentId) }) { prog in
                LoadingIndicator(progress: prog == 1 ? nil : prog)
            }
        }
    }
}

private struct MobileContentSnapshot: Equatable {
    var searchActive = false
    var currentPane: ID<WebContent>?
    var isEmptyPage: Bool = true
    var profileID: ID<Profile>
    var windowBgColor: HSBA?
//    var windowSnapshot: WindowSnapshot
    
    init(state: BrowserState, windowID: ID<WindowState>) {
        guard let window = state.windows[windowID] else {
            self.profileID = .defaultProfile
            return
        }
        self.profileID = window.profile
        let paneData = state.currentPane(forWindow: windowID)
        self.currentPane = paneData?.id
        searchActive = window.searchOverlayActive
        self.isEmptyPage = paneData?.info.isEmptyPage ?? false
        self.windowBgColor = paneData?.info.underPageBackgroundColor
    }
}

struct SearchOrb: View {
    @Environment(\.windowID) private var windowID
    
    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 16))
            .opacity(0.5)
            .frame(both: 70)
            .background {
                Circle().fill(.thinMaterial)
            }
            .onTapGesture {
                if let windowID {
                    BrowserStore.shared.model.windows[windowID]?.searchOverlayActive = true
                }
            }
    }
}
