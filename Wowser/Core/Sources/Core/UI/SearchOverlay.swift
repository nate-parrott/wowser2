import SwiftUI
import Combine

public struct SearchOverlay: View {
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
    
    // Create Searcher with profile-specific history store
    @StateObject private var searcher = Searcher()
    
    @State private var searchText = ""
    @State private var selectedResultIndex = 0
    @State private var contentSize: CGSize = .zero
    
    public var body: some View {
        mainOverlayView
            .onChange(of: searchText) { newValue in
                searcher.query = newValue
                selectedResultIndex = 0 // Reset selection when query changes
            }
            .onAppearOrChange(of: profileID) { profileID in
                searcher.profileID = profileID
            }
    }
    
    // Main overlay container
    private var mainOverlayView: some View {
        ZStack {
            // Semi-transparent background overlay
            Color.black.opacity(0.3)
                .edgesIgnoringSafeArea(.all)
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
            searchInputView
            
            // Results
            if !searcher.results.isEmpty {
                searchResultsList
            }
        }
        .frame(width: 550)
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
                    onSelect: { selectResult(result) }
                )
                .id(index)
            }
        }
        .padding(.vertical, 4)
    }
    
    // Search input field with clear button
    private var searchInputView: some View {
        ZStack(alignment: .leading) {
            // Background
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.windowBackgroundColor))
            
            // Input field
            HStack {
                InputTextField(
                    text: $searchText,
                    options: InputTextFieldOptions(
                        placeholder: "Search or enter website name",
                        font: .systemFont(ofSize: 16),
                        insets: CGSize(width: 16, height: 12),
                        wantsUpDownArrowEvents: true
                    ),
                    focusDate: Date(), // Focus on appear
                    onEvent: handleTextFieldEvent,
                    contentSize: $contentSize
                )
                
                clearButton
            }
        }
        .frame(height: max(44, contentSize.height + 12))
    }
    
    // Clear button that appears when text is entered
    @ViewBuilder
    private var clearButton: some View {
        if !searchText.isEmpty {
            Button(action: {
                searchText = ""
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .padding(.trailing, 8)
        }
    }
    // Handle text field events
    private func handleTextFieldEvent(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter):
            if !searcher.results.isEmpty {
                selectResult(searcher.results[selectedResultIndex])
            } else if !searchText.isEmpty {
                // Handle direct URL or search
                loadQueryOrSearch(searchText)
            }
            
        case .key(.upArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = max(0, selectedResultIndex - 1)
            }
            
        case .key(.downArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = min(searcher.results.count - 1, selectedResultIndex + 1)
            }
            
        case .blur:
            // Optional: dismiss on blur
            break
            
        default:
            break
        }
    }
    
    // Select and process a search result
    private func selectResult(_ result: SearchResult) {
        switch result.item.content {
        case .urlYouTyped(let url):
            loadURL(url)
            
        case .searchWhatYouTyped(let query):
            performSearch(query)
            
        case .searchSuggestion(let query, _):
            performSearch(query)
            
        case .imFeelingLucky(let query):
            // Implement "I'm feeling lucky" functionality
            performImFeelingLucky(query)
            
        case .historyItem(let historyItem):
            loadURL(historyItem.url)
        }
        
        dismissOverlay()
    }
    
    // Load a URL in the current tab or create a new one
    private func loadURL(_ url: URL) {
        guard let windowID = windowID else { return }
        
        BrowserStore.shared.modify { state in
            if let currentTabId = state.windows[windowID]?.currentTab,
               let tab = state.tabs[currentTabId],
               let paneId = tab.panes[tab.focusedPaneIdx]?.id {
                
                state.modifyPaneAndTab(forWebContentId: paneId) { pane, _ in
                    pane.info = WebContent.Info(url: url)
                }
                
                // After state update, we need to load the URL in the WebContent
                DispatchQueue.main.async {
                    if let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneId, toBeActiveInWindow: windowID) {
                        webContent.load(url: url)
                    }
                }
            } else {
                // Create a new tab with the URL
                let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init(url: url))])
                let location = state.insertionIndex(window: windowID, spawningTabId: nil)
                state.insertTab(tab, location: location, inWindow: windowID)
                state.activate(tabId: tab.id, in: windowID)
            }
        }
    }
    
    // Perform a search with the given query
    private func performSearch(_ query: String) {
        // Encode query for search URL
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let searchURL = URL(string: "https://www.google.com/search?q=\(encodedQuery)") {
            loadURL(searchURL)
        }
    }
    
    // Perform "I'm feeling lucky" search
    private func performImFeelingLucky(_ query: String) {
        // Google's "I'm feeling lucky" URL format
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let luckyURL = URL(string: "https://www.google.com/search?q=\(encodedQuery)&btnI") {
            loadURL(luckyURL)
        }
    }
    
    // Handle direct input that could be a URL or search term
    private func loadQueryOrSearch(_ query: String) {
        // Simple URL detection heuristic
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.contains(" ") {
            // Contains spaces, treat as search
            performSearch(trimmed)
            return
        }
        
        if trimmed.contains(".") {
            // May be a URL, try to load directly
            let urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: urlString) {
                loadURL(url)
                return
            }
        }
        
        // Fallback to search
        performSearch(trimmed)
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
                Image(systemName: iconName)
                    .frame(width: 20, height: 20)
                    .foregroundColor(.blue)
                
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

public struct SearchOverlay_Previews: PreviewProvider {
    public static var previews: some View {
        SearchOverlay()
            .withBrowserContext(
                windowID: ID<WindowState>(raw: "w0"),
                profileID: ID<Profile>(raw: "p0")
            )
    }
}
