import SwiftUI

/// A view that displays an appropriate icon for a search result, either a favicon or a system icon
struct SearchIcon: View {
    var item: SearchableItem
    var size: CGFloat = 16
    
    public var body: some View {
        Group {
            switch item.content {
            case .urlYouTyped(let url):
                FaviconView(url: url, size: size)
                
            case .historyItem(let historyItem):
                FaviconView(url: historyItem.url, size: size)
                
            case .searchWhatYouTyped:
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.blue)
                
            case .searchSuggestion:
                Image(systemName: "text.magnifyingglass")
                    .foregroundColor(.blue)
                
            case .imFeelingLucky:
                Image(systemName: "dice")
                    .foregroundColor(.blue)
            }
        }
        .frame(width: size, height: size)
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
