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
        ZStack {
            // Semi-transparent background overlay
            Color.primary.opacity(0.1)
                .edgesIgnoringSafeArea(.all)
                .background(.ultraThinMaterial)
                .onTapGesture {
                    dismissOverlay()
                }
            
            // Search interface
            searchInterfaceView
        }
    }
    
    // Search interface including input and results
    private var searchInterfaceView: some View {
        VStack(spacing: 0) {
            // Search input area
//            searchInputView
            
            // Results
            if !searcher.results.isEmpty {
                searchResultsList
            }
        }
        .frame(width: 550, height: 350, alignment: .top)
        .padding(.vertical)
    }
    
    // Search results list view
    private var searchResultsList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                resultsStack
            }
            .frame(maxHeight: 350)
            .onChange(of: selectedResultIndex) { newValue in
                withAnimation {
                    scrollProxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(Color(.windowBackgroundColor))
        .cornerRadius(6)
    }
    
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
        .padding(.vertical, 4)
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
                
                // Title and URL
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected))
    }
    
    // Computed properties to extract user-friendly data from the SearchResult
    private var title: String {
        switch result.item.content {
        case .searchWhatYouTyped(let query):
            return "Search for \"\(query)\""
        case .urlYouTyped(let url):
            return url.host ?? url.absoluteString
        case .searchSuggestion(let query, _):
            return query
        case .imFeelingLucky(let query):
            return "I'm Feeling Lucky: \(query)"
        case .historyItem(let item):
            return item.title ?? item.url.displayString
        }
    }
    
    private var subtitle: String {
        switch result.item.content {
        case .searchWhatYouTyped:
            return "Search with Google"
        case .urlYouTyped(let url):
            return url.absoluteString
        case .searchSuggestion:
            return "Search suggestion"
        case .imFeelingLucky:
            return "Go directly to first result"
        case .historyItem(let item):
            return item.url.displayString
        }
    }
    
    private var iconName: String {
        switch result.item.content {
        case .searchWhatYouTyped:
            return "magnifyingglass"
        case .urlYouTyped:
            return "globe"
        case .searchSuggestion:
            return "text.magnifyingglass"
        case .imFeelingLucky:
            return "dice"
        case .historyItem:
            return "clock"
        }
    }
}
