import SwiftUI

// Fake copy of PaneView for use in the 3d tab-switcher stack for inactive panes
struct FakePaneView: View {
    var webContentId: ID<WebContent>?
    var focused: Bool
    var singlePane: Bool
    var topbarVisible: Bool
    var toolbarColorScheme: ContentColorScheme?
    
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var size: CGSize = .zero
    
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if let webContentId {
                    FakePaneContent(webContentId: webContentId, toolbarColorScheme: toolbarColorScheme)
                } else {
                    Color.clear
                }
            }
                .padding(.top, topbarLocked ? UIConstants.macHeaderHeight : 0)
                .scaleEffect(y: !topbarLocked && topbarVisible ? (size.height - UIConstants.macHeaderHeight) / max(size.height, 1) : 1, anchor: .bottom)
//                .opacity(snapshot.searchActive ? 0.1 : 1)
            
            Color.clear.frame(height: UIConstants.macHeaderHeight)
                .modifier(WithContentColorScheme(scheme: toolbarColorScheme))
                .shadow(color: Color.black.opacity(topbarVisible ? 0.1 : 0), radius: 5, x: 0, y: 0)
        }
        .overlay {
            if focused, !singlePane {
                Rectangle().strokeBorder(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// Content component for fake pane view
struct FakePaneContent: View {
    var webContentId: ID<WebContent>
    var toolbarColorScheme: ContentColorScheme?
    
    var body: some View {
        WithThumbnail(id: webContentId) { image in
            if let image {
                Color.clear.overlay(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
            } else {
                fallback
            }
        }
    }
    
    @ViewBuilder var fallback: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.pane(forId: webContentId) }) { pane in
            ZStack {
                if let pane {
                    VStack(alignment: .leading) {
                        HStack(spacing: 8) {
                            FaviconView(url: pane.info.url, faviconURL: pane.info.favicon, size: 16)
                            Text(pane.info.title ?? pane.info.url?.absoluteString ?? "")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(8)
                        Spacer()
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WithContentColorScheme(scheme: toolbarColorScheme ?? pane?.info.colorScheme))
        }

    }
}

