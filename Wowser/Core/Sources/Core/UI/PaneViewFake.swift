import SwiftUI

// Fake copy of PaneView for use in the 3d tab-switcher stack for inactive panes
struct FakePaneView: View {
    var webContentId: ID<WebContent>?
    var nativeKey: NativePageKey?
    var focused: Bool
    var singlePane: Bool
    var topbarVisible: Bool
    var toolbarColorScheme: ContentColorScheme?
    var topbarLocked: Bool
    
//    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @State private var size: CGSize = .zero
    
    var body: some View {
        VStack(spacing: 0) {
            if topbarLocked {
                Color.clear.frame(height: UIConstants.macHeaderHeight)
                    .modifier(WithContentColorScheme(scheme: toolbarColorScheme))
                    .shadow(color: Color.black.opacity(topbarVisible ? 0.1 : 0), radius: 5, x: 0, y: 0)
            }
            if let webContentId {
                FakePaneContent(webContentId: webContentId, nativeKey: nativeKey, toolbarColorScheme: toolbarColorScheme)
            } else {
                Color.clear
            }
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
    var nativeKey: NativePageKey?
    var toolbarColorScheme: ContentColorScheme?
    
    var body: some View {
        if let nativeKey {
            NativePanePlaceholder(key: nativeKey)
        } else {
            thumbnail
        }
    }

    private var thumbnail: some View {
        WithThumbnail(id: webContentId) { image in
            if let image {
                Color.clear.overlay(alignment: .topLeading) {
                    image.swiftUI
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
            } else {
                Color("Background", bundle: .module)
                    .overlay {
                        Image(systemName: "globe")
                            .font(.largeTitle)
                            .opacity(0.05)
                    }
            }
        }
    }
}

/// Stand-in for native pages in the tab stack: a big, faint kind icon on a flat
/// background. Native pages render as overlays on an idle WKWebView, so there's
/// nothing cheap to snapshot when switching away.
struct NativePanePlaceholder: View {
    var key: NativePageKey

    var body: some View {
        background.overlay {
            Image(systemName: iconName)
                .font(.system(size: 80))
                .foregroundStyle(key.isTerminal ? Color.white : Color.primary)
                .opacity(0.1)
        }
    }

    @ViewBuilder private var background: some View {
        if key.isTerminal {
            Color.black
        } else {
            Color("Background", bundle: .module)
        }
    }

    private var iconName: String {
        switch key {
        case .terminal: return "terminal"
        case .fileBrowser: return "folder.fill"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .agent: return "sparkles"
        case .welcome: return "hand.wave"
        }
    }
}
