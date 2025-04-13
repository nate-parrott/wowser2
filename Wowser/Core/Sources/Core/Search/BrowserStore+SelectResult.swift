import Foundation

extension BrowserStore {
    func select(result: SearchResult, windowID: ID<WindowState>) {
        switch result.item.content {
        case .urlYouTyped(let url):
            loadURL(url, windowID: windowID)
            
        case .searchWhatYouTyped(let query):
            performSearch(query, windowID: windowID)
            
        case .searchSuggestion(let query, _):
            performSearch(query, windowID: windowID)
            
        case .chatbot(let query):
            performSearch(query, windowID: windowID, chatbot: true)
            
        case .imFeelingLucky(let query):
            // Implement "I'm feeling lucky" functionality
            performImFeelingLucky(query, windowID: windowID)
            
        case .historyItem(let historyItem):
            loadURL(historyItem.url, windowID: windowID)
        }
    }
    
    // Load a URL in the current tab or create a new one
    private func loadURL(_ url: URL, windowID: ID<WindowState>) {
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
    private func performSearch(_ query: String, windowID: ID<WindowState>, chatbot: Bool = false) {
        if chatbot {
            if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://claude.ai/new?q=\(encodedQuery)") {
                loadURL(searchURL, windowID: windowID)
            }
            return
        }
        // Encode query for search URL
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let searchURL = URL(string: "https://www.google.com/search?q=\(encodedQuery)") {
            loadURL(searchURL, windowID: windowID)
        }
    }
    
    // Perform "I'm feeling lucky" search
    private func performImFeelingLucky(_ query: String, windowID: ID<WindowState>) {
        if let luckyURL = URL.duckDuckGoLuckyURL(for: query) {
            loadURL(luckyURL, windowID: windowID)
        }
    }
    
    // Handle direct input that could be a URL or search term
    private func loadQueryOrSearch(_ query: String, windowID: ID<WindowState>) {
        // Simple URL detection heuristic
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.contains(" ") {
            // Contains spaces, treat as search
            performSearch(trimmed, windowID: windowID)
            return
        }
        
        if trimmed.contains(".") {
            // May be a URL, try to load directly
            let urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: urlString) {
                loadURL(url, windowID: windowID)
                return
            }
        }
        
        // Fallback to search
        performSearch(trimmed, windowID: windowID)
    }

}
