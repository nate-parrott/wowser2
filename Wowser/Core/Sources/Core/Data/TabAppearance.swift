import Foundation
import SwiftUI

// Tab appearance overrides

struct TabAppearance: Equatable, Codable {
    enum Icon: Equatable, Codable {
        case favicon(URL?) // image url
        case sfSymbol(String)
        case emoji(String) // user-chosen tab icon
        case terminal(running: Bool) // terminal-glyph chip; dimmed when idle at the prompt
        case vscode  // VS Code-glyph chip
        case files   // file-browser-glyph chip
        case fileIcon(path: String) // the Finder icon for a specific file on disk
        case agentFruit(flavor: AgentFruitFlavor, working: Bool) // agent-tab fruit; eyes open while working
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
    /// The LRU unloader dropped this pane's web content (chat-mode spaces);
    /// shown dimmed until it's reopened.
    var isUnloaded = false
    /// Title is a user-provided custom name; rendered italic.
    var isCustomTitle = false

    static var empty: TabAppearance {
        .init(title: "", icon: .empty, urlFieldTextSelected: "", urlFieldTextDeselected: "")
    }
}

extension Pane {
    func tabAppearance() -> TabAppearance {
        // Prefer base favicon and title if they exist
        var appearance = TabAppearance(
            title: baseInfo?.title?.nilIfEmpty ?? info.title?.nilIfEmpty ?? info.url?.hostWithoutWWW ?? "",
            icon: .empty,
            urlFieldTextSelected: info.url?.absoluteString ?? "",
            urlFieldTextDeselected: info.url?.hostWithoutWWW ?? ""
        )
        if info.isEmptyPage {
            appearance.title = "New"
            appearance.specialTitle = true
        }
        
        if let faviconUrl = baseInfo?.favicon ?? info.favicon ?? info.url?.inferredFaviconURL {
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
        if agentActiveUntil != nil {
            appearance.subtitle = "Agent is using this tab"
        }
        if unloaded == true {
            appearance.isUnloaded = true
        }

        if let url = info.url, let nativeKey = NativePageKey(url: url) {
            appearance = nativeKey.tabAppearance(info: info, baseInfo: baseInfo)
        }

        if let download {
            appearance.title = download.suggestedFilename
            appearance.icon = .fileIcon(path: download.destinationURL.path)
            switch download.status {
            case .inProgress:
                appearance.subtitle = download.estimatedSize > 0
                    ? "Downloading… \(Int(download.progress * 100))%"
                    : "Downloading…"
            case .failed:
                appearance.subtitle = "Download failed"
            case .cancelled:
                appearance.subtitle = "Download cancelled"
            case .completed:
                break
            }
        }

        if let url = info.url, let genKey = GeneratedPageKey(url: url) {
            switch genKey {
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
        
        // appearance for errored tabs, which may not have titles + urls
        if appearance.urlFieldTextDeselected.isEmpty && appearance.urlFieldTextSelected.isEmpty, let failedURL = info.failedNavToURL?.url {
            appearance.urlFieldTextSelected = failedURL.absoluteString
            appearance.urlFieldTextDeselected = failedURL.hostWithoutWWW
        }
        if appearance.title.isEmpty, let failedURL = info.failedNavToURL?.url {
            appearance.title = failedURL.hostWithoutWWW
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
        if let custom = customTitle?.nilIfEmpty {
            appearance.title = custom
            appearance.isCustomTitle = true
            appearance.specialTitle = false
        }
        if let emoji = customEmoji?.nilIfEmpty {
            appearance.icon = .emoji(emoji)
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

        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 16, height: 16)

        case .terminal(let running):
            TerminalFavicon(running: running)
        case .agentFruit(let flavor, let working):
            AgentFruitIcon(flavor: flavor, working: working)
        case .vscode:
            VSCodeFavicon()
        case .files:
            FileBrowserFavicon()
        case .fileIcon(let path):
            FileIconView(path: path)
        case .empty:
            Circle()
                .fill(.primary)
                .opacity(0.1)
                .frame(width: 16, height: 16)
        }

    }
}

struct TerminalFavicon: View {
    /// Black chip while a command runs; a lighter gray at the prompt.
    var running = false

    var body: some View {
        TintedGlyph(icon: "terminal", fg: Color.white, bg: running ? Color.black : Color(white: 0.42))
    }
}

struct VSCodeFavicon: View {
    var body: some View {
        TintedGlyph(icon: "chevron.left.forwardslash.chevron.right", fg: Color(hex: 0x2B65A6), bg: Color.white)
    }
}

struct FileBrowserFavicon: View {
    var size: CGFloat = 16
    var body: some View {
        TabIconView(icon: .sfSymbol("folder"))
    }
}

/// The Finder icon for a file. Looked up off the body path (on appear / path
/// change) so the syscall doesn't run on every re-render.
struct FileIconView: View {
    var path: String
    #if os(macOS)
    @State private var image: NSImage?
    #endif

    var body: some View {
        #if os(macOS)
        Group {
            if let image {
                Image(nsImage: image).resizable().frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .onAppearOrChange(of: path) { path in
            image = NSWorkspace.shared.icon(forFile: path)
        }
        #else
        TabIconView(icon: .sfSymbol("doc"))
        #endif
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
