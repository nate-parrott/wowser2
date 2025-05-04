import SwiftUI
import Combine

/// A mobile-optimized search overlay for iOS devices
struct MobileSearchOverlay: View {
    let windowID: ID<WindowState>
    @Binding var isPresented: Bool
    
    @State private var searchText: String = ""
    @State private var selectedResultIndex: Int = 0
    
    private let searcher = Searcher()
    
    init(windowID: ID<WindowState>, isPresented: Binding<Bool>) {
        self.windowID = windowID
        self._isPresented = isPresented
    }
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    dismissOverlay()
                }
            
            VStack(spacing: 0) {
                // Search header section
                searchHeaderSection
                
                // Search results
                searchResultsList
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
        }
        .padding(.bottom, 8)
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
    
    // MARK: - Search Results
    
    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(searcher.results.enumerated()), id: \\.element.id) { index, result in
                    searchResultRow(result: result, isSelected: index == selectedResultIndex)
                        .id(index)
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemBackground))
    }
    
    private func searchResultRow(result: SearchResult, isSelected: Bool) -> some View {
        Button {
            BrowserStore.shared.select(result: result, windowID: windowID)
            dismissOverlay()
        } label: {
            HStack(spacing: 12) {
                // Icon
                SearchIcon(item: result.item, size: 24, selected: isSelected)
                    .padding(8)
                
                // Label
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleForResult(result))
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if let subtitle = subtitleForResult(result) {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Helper Methods
    
    private func titleForResult(_ result: SearchResult) -> String {
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
    
    private func subtitleForResult(_ result: SearchResult) -> String? {
        switch result.item.content {
        case .urlYouTyped(let url):
            return url.absoluteString
        case .historyItem(let item):
            return item.url.absoluteString
        case .tab:
            return "Switch to Tab"
        default:
            return nil
        }
    }
    
    private func dismissOverlay() {
        isPresented = false
    }
}