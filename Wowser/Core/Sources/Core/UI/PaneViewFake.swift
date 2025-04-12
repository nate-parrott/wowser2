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
            content
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
    
    @ViewBuilder private var content: some View {
        Color.red // TODO: show thumbnail
    }
}
