import SwiftUI

/// A view that displays an appropriate icon for a search result, either a favicon or a system icon
struct SearchIcon: View {
    var item: SearchableItem
    var size: CGFloat = 16
    var selected = false
    
    public var body: some View {
        let iconOpacity: CGFloat = selected ? 1 : 0.4
        Group {
            switch item.content {
            case .urlYouTyped(let url):
                if let nativeKey = NativePageKey(url: url) {
                    nativeKey.favicon(size: size)
                } else {
                    FaviconView(faviconURL: url.inferredFaviconURL, size: size)
                }
                
            case .historyItem(let historyItem):
                if let nativeKey = NativePageKey(url: historyItem.url) {
                    nativeKey.favicon(size: size)
                } else {
                    FaviconView(faviconURL: historyItem.url.inferredFaviconURL, size: size)
                }
                
            case .searchWhatYouTyped:
                Image(systemName: "magnifyingglass")
                    .opacity(iconOpacity)
//                    .foregroundColor(.blue)
                
            case .chatbot:
                Image(systemName: "questionmark.bubble")
                    .opacity(iconOpacity)
                
            case .searchSuggestion:
                Image(systemName: "magnifyingglass")
                    .opacity(iconOpacity)
//                    .foregroundColor(.blue)
                
            case .imFeelingLucky:
                Image(systemName: "arrow.forward.circle.fill")
                    .opacity(iconOpacity)
//                    .foregroundColor(.blue)
                
            case .searchAction(let action):
                if case .openURL(let url) = action, let nativeKey = NativePageKey(url: url) {
                    nativeKey.favicon(size: size)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .opacity(iconOpacity)
                }

            case .terminalCommand:
                TerminalFavicon(running: true)
                
            case .askAgent:
                AgentFruitIcon(flavor: .cherry, working: false, size: size)
                    .opacity(selected ? 1 : 0.7)

            case .tab(_, let info):
                Group {
                    if let url = info.url, let nativeKey = NativePageKey(url: url) {
                        nativeKey.favicon(size: size)
                    } else {
                        FaviconView(faviconURL: info.favicon ?? info.url?.inferredFaviconURL, size: size)
                    }
                }
                .overlay(alignment: .leading) {
                    SwitchToTabBadge(selected: selected)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SwitchToTabBadge: View {
    var selected: Bool
    
    var body: some View {
        Image(systemName: "arrow.right.circle.fill")
            .font(.system(size: 12))
//            .foregroundStyle(selected ? Color.orange : Color.primary)
            .frame(both: 16)
            .background(Circle().fill(selected ? Color.gray : Color("Background", bundle: .module)))
            .frame(both: 1)
    }
}

#Preview {
    VStack(spacing: 20) {
        if let url = URL(string: "https://www.apple.com") {
            SearchIcon(item: SearchableItem(id: .init(raw: "test1"), content: .urlYouTyped(url)))
            
            SearchIcon(item: SearchableItem(id: .init(raw: "test2"), content: .searchWhatYouTyped("search query")))
            
//            SearchIcon(item: SearchableItem(id: .init(raw: "test3"), content: .historyItem(HistoryItem(url: url, title: "Apple", firstVisit: Date(), lastVisit: Date(), visitCount: 10))))
            
            SearchIcon(item: SearchableItem(id: .init(raw: "test4"), content: .searchSuggestion("suggestion", 1)))
            
            SearchIcon(item: SearchableItem(id: .init(raw: "test5"), content: .imFeelingLucky("feeling lucky")))
        }
    }
    .padding()
}
