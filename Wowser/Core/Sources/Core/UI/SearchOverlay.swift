import SwiftUI
import Combine

public struct SearchResultsOverlay: View {
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int
    @ObservedObject var searcher: Searcher
    
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
            
    public var body: some View {
        mainOverlayView
    }
    
    // Main overlay container
    private var mainOverlayView: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    dismissOverlay()
                }
            
            // Search interface
            resultsStack
                .frame(maxWidth: 500)
        }
    }
    
//    // Search results list view
//    private var searchResultsList: some View {
//        ScrollViewReader { scrollProxy in
//            ScrollView {
//                resultsStack
//            }
//            .frame(maxHeight: 350)
//            .onChange(of: selectedResultIndex) { newValue in
//                withAnimation {
//                    scrollProxy.scrollTo(newValue, anchor: .center)
//                }
//            }
//        }
//    }
    
    // Results stack containing all result rows
    private var resultsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(searcher.results.enumerated()), id: \.element.id) { index, result in
                SearchResultRow(
                    result: result,
                    isSelected: index == selectedResultIndex,
                    onSelect: {
                        if let windowID {
                            BrowserStore.shared.select(result: result, windowID: windowID)
                        }
                        dismissOverlay()
                    }
                )
                .id(index)
            }
        }
        .padding(12)
    }
    
    // Dismiss the search overlay
    private func dismissOverlay() {
        BrowserStore.shared.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = false
            }
        }
    }
}

// Search result row component for displaying a SearchResult
private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Icon
                SearchIcon(item: result.item, size: 20)
                
                Text(title + "  ")
                    .font(.system(size: 14))
                    .layoutPriority(2)
                
                Text(subtitle ?? "")
                    .font(.system(size: 12))
                    .layoutPriority(1)
                    .opacity(0.5)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .lineLimit(1)
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected, result: result))
    }
    
    // Computed properties to extract user-friendly data from the SearchResult
    private var title: String {
        switch result.item.content {
        case .searchWhatYouTyped(let query):
            return query
        case .urlYouTyped(let url):
            return url.displayString
        case .searchSuggestion(let query, _):
            return query
        case .imFeelingLucky(let query):
            return query
        case .historyItem(let item):
            return item.title ?? item.url.displayString
        case .chatbot(let query):
            return query
        }
    }
    
    private var subtitle: String? {
        switch result.item.content {
        case .searchWhatYouTyped:
            return nil
        case .urlYouTyped(let url):
            return url.absoluteString
        case .searchSuggestion:
            return nil
        case .imFeelingLucky:
            return "Go Direct"
        case .chatbot:
            return "Chat"
        case .historyItem(let item):
            return item.url.displayString
        }
    }
}
