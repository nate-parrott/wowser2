import SwiftUI

/// A view that displays an appropriate icon for a search result, either a favicon or a system icon
struct SearchIcon: View {
    var item: SearchableItem
    var size: CGFloat = 16
    var selected = false
    
    public var body: some View {
        Group {
            switch item.content {
            case .urlYouTyped(let url):
                FaviconView(url: url, size: size)
                
            case .historyItem(let historyItem):
                FaviconView(url: historyItem.url, size: size)
                
            case .searchWhatYouTyped:
                Image(systemName: "magnifyingglass")
//                    .foregroundColor(.blue)
                
            case .chatbot:
                Image(systemName: "questionmark.bubble")
                
            case .searchSuggestion:
                Image(systemName: "magnifyingglass")
//                    .foregroundColor(.blue)
                
            case .imFeelingLucky:
                Image(systemName: "arrow.forward.circle.fill")
//                    .foregroundColor(.blue)
                
            case .tab(_, let info):
                FaviconView(url: info.url, faviconURL: info.favicon, size: size)
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
