import SwiftUI
import Foundation

extension WebContent.Info {
    fileprivate func detectSearchContext() -> SearchContext? {
        guard let url = committedURL else { return nil }
        
        // Check for GeneratedPageKey search pages
        if let generatedPageKey = GeneratedPageKey(url: url) {
            switch generatedPageKey {
            case .webSearch(let query, _):
                return SearchContext(query: query, currentType: .webSearch)
            case .imageSearch(let query, _):
                return SearchContext(query: query, currentType: .imageSearch)
            case .homepage:
                return nil
            }
        }
        
        // Check for Google search
        if let query = url.parsedAsGoogleSearchQuery {
            return SearchContext(query: query, currentType: .google)
        }
        
        // Check for Google Maps
        if url.host?.contains("maps.google.") == true,
           let query = url.queryParam(name: "q") {
            return SearchContext(query: query, currentType: .maps)
        }
        
        // Check for YouTube
        if url.host?.contains("youtube.com") == true,
           url.path.contains("/results"),
           let query = url.queryParam(name: "search_query") {
            return SearchContext(query: query, currentType: .youtube)
        }
        
        return nil
    }
}

struct SearchToolbarIfNeeded: View {
    let webContentId: ID<WebContent>?
    let colorScheme: ContentColorScheme?
    
    @AppStorage(DefaultsKeys.searchToolbarEnabled.rawValue) private var searchToolbarEnabled = false
    
    var body: some View {
        if searchToolbarEnabled, let webContentId {
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.pane(forId: webContentId)?.info.detectSearchContext() }, main: { ctx in
                if let ctx {
                    SearchToolbar(context: ctx, colorScheme: colorScheme, webContentId: webContentId)
                }
            })
            .id(webContentId)
        }
    }
}

struct SearchContext: Equatable {
    let query: String
    let currentType: SearchType
}

enum SearchType: CaseIterable {
    case webSearch
    case imageSearch
    case google
    case maps
    case youtube
    
    var displayName: String {
        switch self {
        case .webSearch: return "Web"
        case .imageSearch: return "Images"
        case .google: return "Google"
        case .maps: return "Maps"
        case .youtube: return "YouTube"
        }
    }
    
    var icon: String {
        switch self {
        case .webSearch: return "doc.text.magnifyingglass"
        case .imageSearch: return "photo.on.rectangle"
        case .google: return "globe"
        case .maps: return "map"
        case .youtube: return "play.rectangle"
        }
    }
}

private struct SearchToolbar: View {
    let context: SearchContext
    let colorScheme: ContentColorScheme?
    let webContentId: ID<WebContent>
    
    @Environment(\.windowID) private var windowID
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(SearchType.allCases, id: \.self) { searchType in
                button(forType: searchType)
//                SearchTypeButton(
//                    searchType: searchType,
//                    query: context.query,
//                    isSelected: searchType == context.currentType,
//                    colorScheme: colorScheme,
//                    webContentId: webContentId
//                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            (colorScheme?.background.color ?? Color(.windowBackgroundColor))
                .opacity(0.9)
        }
        .overlay {
            Rectangle()
                .fill(colorScheme?.foreground.color ?? Color.primary)
                .opacity(0.1)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
    
    @ViewBuilder func button(forType type: SearchType) -> some View {
        let selected = context.currentType == type
        FreeformButton(action: { switchToSearchType(type) }) { state in
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                Text(type.displayName)
            }
                .font(.footnote.weight(.medium))
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background {
                    Capsule(style: .continuous)
                        .opacity(state == .pressed ? 0.15 : (state == .hovered ? 0.1 : (selected ? 0.1 : 0)))
                }
                .foregroundStyle(colorScheme?.foreground.color ?? .primary)
                .opacity(state == .hovered || state == .pressed || selected ? 1 : 0.66)
        }
    }
    
    func switchToSearchType(_ type: SearchType) {
        guard let windowID = windowID else { return }
        let query = context.query
        
        let targetURL: URL
        
        switch type {
        case .webSearch:
            targetURL = GeneratedPageKey.webSearch(q: query).url
        case .imageSearch:
            targetURL = GeneratedPageKey.imageSearch(q: query).url
        case .google:
            targetURL = SearchEngine.google.urlForQuery(query)
        case .maps:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "maps.google.com"
            components.path = "/maps"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            targetURL = components.url ?? SearchEngine.google.urlForQuery(query)
        case .youtube:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.youtube.com"
            components.path = "/results"
            components.queryItems = [URLQueryItem(name: "search_query", value: query)]
            targetURL = components.url ?? SearchEngine.google.urlForQuery(query)
        }
        
        BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID)?.load(url: targetURL)
    }
}
//
//private struct SearchTypeButton: View {
//    let searchType: SearchType
//    let query: String
//    let isSelected: Bool
//    let colorScheme: ContentColorScheme?
//    let webContentId: ID<WebContent>
//    
//    @Environment(\.windowID) private var windowID
//    @State private var hovered = false
//    
//    var body: some View {
//        Button(action: navigateToSearchType) {
//            HStack(spacing: 4) {
//                Image(systemName: searchType.icon)
//                    .font(.system(size: 12, weight: .medium))
//                Text(searchType.displayName)
//                    .font(.system(size: 13, weight: .medium))
//            }
//            .foregroundColor(isSelected ? Color.accentColor : (colorScheme?.foreground.color ?? Color.primary))
//            .padding(.horizontal, 12)
//            .padding(.vertical, 6)
//            .background {
//                if isSelected {
//                    RoundedRectangle(cornerRadius: 6)
//                        .fill(Color.accentColor)
//                        .opacity(0.1)
//                } else if hovered {
//                    RoundedRectangle(cornerRadius: 6)
//                        .fill(colorScheme?.foreground.color ?? Color.primary)
//                        .opacity(0.05)
//                }
//            }
//        }
//        .buttonStyle(PlainButtonStyle())
//        .onHover { self.hovered = $0 }
//        .disabled(isSelected)
//    }
//    
//    private func navigateToSearchType() {
//        guard let windowID = windowID else { return }
//        
//        let targetURL: URL
//        
//        switch searchType {
//        case .webSearch:
//            targetURL = GeneratedPageKey.webSearch(q: query).url
//        case .imageSearch:
//            targetURL = GeneratedPageKey.imageSearch(q: query).url
//        case .google:
//            targetURL = SearchEngine.google.urlForQuery(query)
//        }
//        
//        BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID)?.load(url: targetURL)
//        
////        BrowserStore.shared.modify { state in
////            guard let window = state.windows[windowID],
////                  let currentTabId = window.currentTab,
////                  let tab = state.tabs[currentTabId],
////                  let currentPaneId = tab.panes[tab.focusedPaneIdx]?.id else {
////                return
////            }
////            
////            state.modifyPaneAndTab(forWebContentId: currentPaneId) { pane, _ in
////                pane.info = WebContent.Info(url: targetURL)
////            }
////        }
//    }
//}
