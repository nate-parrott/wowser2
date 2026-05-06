import Foundation
import SwiftUI

// Tab appearance overrides

struct TabAppearance: Equatable, Codable {
    enum Icon: Equatable, Codable {
        case favicon(URL?) // image url
        case sfSymbol(String)
        case terminal // terminal-glyph chip for native terminal tabs
        case vscode  // VS Code-glyph chip
        case files   // file-browser-glyph chip
        case empty
    }
    
    var title: String
    var specialTitle = false // eg for new tabs
    var icon: Icon
    var urlFieldTextSelected: String
    var urlFieldTextDeselected: String
    /// Subtitle to show under the title in the sidebar — e.g. "Agent tab" for ghost panes.
    var subtitle: String?
    /// Ghost panes are shown muted/dimmed.
    var isGhost = false

    static var empty: TabAppearance {
        .init(title: "", icon: .empty, urlFieldTextSelected: "", urlFieldTextDeselected: "")
    }
}

extension Pane {
    func tabAppearance() -> TabAppearance {
        var appearance = TabAppearance(
            title: info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty ?? info.url?.hostWithoutWWW ?? "",
            icon: .empty,
            urlFieldTextSelected: info.url?.absoluteString ?? "",
            urlFieldTextDeselected: info.url?.hostWithoutWWW ?? ""
        )
        if info.isEmptyPage {
            appearance.title = "New"
            appearance.specialTitle = true
        }
        if let faviconUrl = info.favicon ?? baseInfo?.favicon ?? info.url?.inferredFaviconURL {
            appearance.icon = .favicon(faviconUrl)
        }
                
        // Handle Google search pages
        if let url = info.url, let searchQuery = url.parsedAsGoogleSearchQuery {
            appearance.title = searchQuery
            appearance.icon = .sfSymbol("magnifyingglass")
            appearance.urlFieldTextSelected = searchQuery
            appearance.urlFieldTextDeselected = searchQuery
        }
        
        // Handle DuckDuckGo "I'm feeling lucky" pages
        if let url = info.url, let q = url.parsedAsDuckDuckGoLuckyQuery {
            appearance.title = ""
            appearance.icon = .empty
            appearance.urlFieldTextDeselected = q
        }
        
        // Also override DDG link-redirect urls
        if let url = info.url, url.hasRootHost("duckduckgo.com"), url.path == "/l" {
            appearance.title = ""
            appearance.icon = .empty
            appearance.urlFieldTextDeselected = ""
        }
        
        if isGhost {
            appearance.subtitle = "Agent tab"
            appearance.isGhost = true
        }

        if let url = info.url, let nativeKey = NativePageKey(url: url) {
            switch nativeKey {
            case .terminal:
                appearance.icon = .terminal
                let titleFromTerm = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
                appearance.title = titleFromTerm ?? "Terminal"
                appearance.urlFieldTextSelected = appearance.title
                appearance.urlFieldTextDeselected = appearance.title
            case .vscode(_, let folder):
                appearance.icon = .vscode
                let liveTitle = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
                let folderName = folder.flatMap { ($0 as NSString).lastPathComponent.nilIfEmpty }
                appearance.title = liveTitle ?? folderName ?? "VS Code"
                appearance.urlFieldTextSelected = appearance.title
                appearance.urlFieldTextDeselected = appearance.title
            case .fileBrowser(_, let path):
                appearance.icon = .files
                let liveTitle = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
                let pathName: String? = {
                    guard let path else { return nil }
                    if path == "/" { return "/" }
                    return ((path as NSString).expandingTildeInPath as NSString).lastPathComponent.nilIfEmpty
                }()
                appearance.title = liveTitle ?? pathName ?? "Files"
                appearance.urlFieldTextSelected = appearance.title
                appearance.urlFieldTextDeselected = appearance.title
            }
        }

        if let url = info.url, let genKey = GeneratedPageKey(url: url) {
            switch genKey {
            case .homepage:
                appearance.icon = .sfSymbol("leaf")
                appearance.title = "Home"
                appearance.urlFieldTextSelected = ""
                appearance.urlFieldTextDeselected = "Home"
            case .webSearch(let q, _):
                appearance.icon = .sfSymbol("magnifyingglass")
                appearance.title = q
                appearance.urlFieldTextSelected = q
                appearance.urlFieldTextDeselected = q
            case .imageSearch(let q, _):
                appearance.icon = .sfSymbol("photo.on.rectangle")
                appearance.title = "Images: \(q)"
                appearance.urlFieldTextSelected = q
                appearance.urlFieldTextDeselected = "Images: \(q)"
            }
        }
        
        return appearance
    }
}

extension Tab {
    func appearance() -> TabAppearance {
        var appearance = self.panes.first?.tabAppearance() ?? .empty
        // Use special icons for splits:
        switch panes.count {
        case 2:
            appearance.icon = .sfSymbol("2.circle.fill")
        case 3:
            appearance.icon = .sfSymbol("3.circle.fill")
        case 4:
            appearance.icon = .sfSymbol("4.circle.fill")
        case 5:
            appearance.icon = .sfSymbol("5.circle.fill")
        default: ()
        }
        return appearance
    }
}

struct TabIconView: View {
    var icon: TabAppearance.Icon

    var body: some View {
        switch icon {
        case .favicon(let faviconURL):
            FaviconView(faviconURL: faviconURL)

        case .sfSymbol(let symbolName):
            Image(systemName: symbolName)
                .foregroundColor(.accentColor)
                .font(.system(size: 12))
                .frame(width: 16, height: 16)

        case .terminal:
            TintedGlyph(icon: "terminal", fg: Color.white, bg: Color.black)
        case .vscode:
            TintedGlyph(icon: "chevron.left.forwardslash.chevron.right", fg: Color(hex: 0x2B65A6), bg: Color.white)
        case .files:
            TintedGlyph(icon: "folder", fg: Color.accentColor, bg: Color(.background).opacity(0.15), blurBg: true)
        case .empty:
            Circle()
                .fill(.primary)
                .opacity(0.1)
                .frame(width: 16, height: 16)
        }

    }
}

private struct TintedGlyph: View {
    var icon: String
    var fg: Color
    var bg: Color
    var size: CGFloat = 16
    var blurBg = false
    
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            if blurBg {
                Color.clear.background(.thinMaterial)
            }
            
            bg
                        
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(fg)
//                .blendMode(.overlay)
            LinearGradient(colors: [Color.white, Color.black], startPoint: .top, endPoint: .bottom)
                .blendMode(.luminosity)
                .opacity(0.1)

        }
        .frame(both: 16)
        .clipShape(shape)
        .shadow(color: bg.opacity(0.1), radius: 3, x: 0, y: 1)
        .overlay {
            shape.strokeBorder(fg, lineWidth: 1).opacity(0.1)
        }
    }
}
