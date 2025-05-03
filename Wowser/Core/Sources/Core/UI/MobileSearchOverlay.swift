import SwiftUI
import Combine

/// A mobile-optimized search overlay with launcher-style interface
/// Displays a search bar and search results in a fullscreen overlay
public struct MobileSearchOverlay: View {
    let windowID: ID<WindowState>
    @Binding var isPresented: Bool
    
    @State private var searchText: String = ""
    @State private var selectedResultIndex: Int = 0
    
    private let searcher = Searcher()
    
    public init(windowID: ID<WindowState>, isPresented: Binding<Bool>) {
        self.windowID = windowID
        self._isPresented = isPresented
    }
    
    public var body: some View {
        ZStack {
            // Blurred background
            if #available(iOS 15.0, *) {
                Color.black.opacity(0.15)
                    .background(.ultraThinMaterial)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        dismissOverlay()
                    }
            } else {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        dismissOverlay()
                    }
            }
            
            VStack(spacing: 0) {
                // Search header section
                searchHeaderSection
                
                // Search results with launcher-style UI
                searchResultsGrid
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // Begin searching with empty query
            searcher.search(searchText)
        }
    }
    
    // MARK: - Search Header
    
    private var searchHeaderSection: some View {
        VStack(spacing: 16) {
            HStack {
                // Search input field
                searchField
                
                // Cancel button
                Button {
                    dismissOverlay()
                } label: {
                    Text("Cancel")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            
            // Provider selection
            providerSelector
                .padding(.bottom, 8)
        }
        .background(Color(UIColor.systemBackground))
    }
    
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search or enter website name", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .onChange(of: searchText) { newValue in
                    // Reset selection index when text changes
                    selectedResultIndex = 0
                    
                    // Perform search with debounce
                    searcher.search(newValue)
                }
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(10)
        .accentColor(.accentColor)
    }
    
    private var providerSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(SearchProviderOption.allCases, id: \.self) { provider in
                    providerButton(provider)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    private func providerButton(_ provider: SearchProviderOption) -> some View {
        Button {
            searcher.searchProvider = provider.searchProvider
            // Re-search with current term
            searcher.search(searchText)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: provider.iconName)
                    .font(.system(size: 14))
                Text(provider.displayName)
                    .font(.system(size: 14))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(searcher.searchProvider == provider.searchProvider ? 
                          Color.accentColor.opacity(0.15) : Color(UIColor.systemGray6))
            )
            .foregroundColor(searcher.searchProvider == provider.searchProvider ? 
                            .accentColor : .primary)
        }
    }
    
    // MARK: - Search Results Grid
    
    private var searchResultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 20) {
                // Search results as grid items
                ForEach(Array(searcher.results.enumerated()), id: \.element.id) { index, result in
                    searchResultGridItem(result: result, isSelected: index == selectedResultIndex)
                        .id(index)
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemBackground).opacity(0.95))
    }
    
    private func searchResultGridItem(result: SearchResult, isSelected: Bool) -> some View {
        Button {
            if let windowID = windowID {
                BrowserStore.shared.select(result: result, windowID: windowID)
            }
            dismissOverlay()
        } label: {
            VStack(spacing: 8) {
                // Icon
                SearchIcon(item: result.item, size: 32, selected: isSelected)
                    .padding(16)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(UIColor.systemGray6))
                    )
                
                // Label
                Text(resultDisplayTitle(result))
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 100)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func resultDisplayTitle(_ result: SearchResult) -> String {
        switch result.item.content {
        case .searchWhatYouTyped(let query):
            return "Search for \"\(query)\""
        case .urlYouTyped(let url):
            return url.host ?? url.absoluteString
        case .searchSuggestion(let query, _):
            return query
        case .imFeelingLucky(let query):
            return "Lucky: \(query)"
        case .historyItem(let item):
            return item.title ?? item.url.host ?? item.url.absoluteString
        case .chatbot(let query):
            return "Chat: \(query)"
        case .tab(_, let info):
            return info.title ?? "Tab"
        }
    }
    
    // MARK: - Helper Methods
    
    private func dismissOverlay() {
        isPresented = false
    }
}

// MARK: - Search Provider Options

private enum SearchProviderOption: String, CaseIterable {
    case google
    case duckduckgo
    case bing
    case history
    
    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .history: return "History"
        }
    }
    
    var iconName: String {
        switch self {
        case .google: return "globe"
        case .duckduckgo: return "duck"
        case .bing: return "b.circle"
        case .history: return "clock"
        }
    }
    
    var searchProvider: SearchProvider {
        switch self {
        case .google: return .google
        case .duckduckgo: return .duckduckgo
        case .bing: return .bing
        case .history: return .history
        }
    }
}