import Foundation
import SwiftUI

// Tab appearance overrides

struct TabAppearance: Equatable, Codable {
    enum Icon: Equatable, Codable {
        case favicon(URL?) // image url
        case sfSymbol(String)
        case empty
    }
    
    var title: String
    var icon: Icon
    var urlFieldTextSelected: String
    var urlFieldTextDeselected: String
    
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
        
        if let url = info.url, let genKey = GeneratedPageKey(url: url) {
            switch genKey {
            case .homepage:
                appearance.icon = .sfSymbol("leaf")
                appearance.title = "Home"
                appearance.urlFieldTextSelected = ""
                appearance.urlFieldTextDeselected = "Home"
            case .answer(let q):
                appearance.icon = .sfSymbol("magnifyingglass")
                appearance.title = q
                appearance.urlFieldTextSelected = q
                appearance.urlFieldTextDeselected = q
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
            
        case .empty:
            Circle()
                .fill(.primary)
                .opacity(0.1)
                .frame(width: 16, height: 16)
        }

    }
}
