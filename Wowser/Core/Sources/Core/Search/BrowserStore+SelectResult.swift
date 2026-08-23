import Foundation

extension BrowserStore {
    func select(result: SearchResult, windowID: ID<WindowState>, forceNewTab: Bool = false) {
        // Dont force new tab if current tab is empty
        var forceNewTab = forceNewTab
        if model.currentPane(forWindow: windowID)?.info.isEmptyPage ?? false {
            forceNewTab = false
        }
        
        switch result.item.content {
        case .urlYouTyped(let url):
            loadURL(url, windowID: windowID, forceNewTab: forceNewTab)
            
        case .searchWhatYouTyped(let query):
            performSearch(query, windowID: windowID, forceNewTab: forceNewTab)
            
        case .searchSuggestion(let query, _):
            performSearch(query, windowID: windowID, forceNewTab: forceNewTab)
            
        case .chatbot(let query):
            performSearch(query, windowID: windowID, chatbot: true, forceNewTab: forceNewTab)
            
        case .imFeelingLucky(let query):
            // Implement "I'm feeling lucky" functionality
            performImFeelingLucky(query, windowID: windowID, forceNewTab: forceNewTab)
            
        case .historyItem(let historyItem):
            loadURL(historyItem.url, windowID: windowID, forceNewTab: forceNewTab)
            
        case .tab(let tabId, _):
            // Activate the existing tab and close current tab if it's empty
            modify { state in
                // Are we in an empty new tab? if so we'll wanna close it when we switch
                if let currentTabId = state.windows[windowID]?.currentTab,
                   let currentTab = state.tabs[currentTabId],
                   currentTab.panes.count == 1,
                   let currentPane = currentTab.panes[currentTab.focusedPaneIdx],
                   currentPane.info.isEmptyPage {
                    
                    // First activate the target tab
                    state.activate(tabId: tabId, in: windowID)
                    
                    DispatchQueue.main.async {
                        self.close(webContentId: currentPane.id, removeIfPinned: false)
                    }
                } else {
                    // Just activate the target tab
                    state.activate(tabId: tabId, in: windowID)
                }
            }
            
        case .searchAction(let action):
            performSearchAction(action: action, windowID: windowID)

        case .askAgent(let query, _):
            #if os(macOS)
            Task { @MainActor in
                AgentChatTabs.ask(query: query, windowID: windowID)
            }
            #endif
        }
    }
    
    // Load a URL in the current tab or create a new one.
    // If `via` is given, it's loaded first so it lands in the back stack
    // (e.g. the search results page behind a go-direct navigation).
    private func loadURL(_ url: URL, via: URL? = nil, windowID: ID<WindowState>, forceNewTab: Bool) {
        BrowserStore.shared.modify { state in
            let paneId: ID<WebContent>
            if !forceNewTab,
               let currentTabId = state.windows[windowID]?.currentTab,
               let tab = state.tabs[currentTabId],
               let focusedPaneId = tab.panes[tab.focusedPaneIdx]?.id {
                paneId = focusedPaneId
                state.modifyPaneAndTab(forWebContentId: paneId) { pane, _ in
                    pane.info = WebContent.Info(url: via ?? url)
                }
            } else {
                // Create a new tab with the URL
                paneId = .assign()
                let tab = Tab(id: .assign(), panes: [.init(id: paneId, info: .init(url: via ?? url))])
                let location = state.insertionIndex(window: windowID, spawningTabId: nil)
                state.insertTab(tab, location: location, inWindow: windowID)
                state.activate(tabId: tab.id, in: windowID)
            }

            // After state update, load the URL in the WebContent
            DispatchQueue.main.async {
                if let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneId, toBeActiveInWindow: windowID) {
                    if let via {
                        webContent.load(url: via, thenLoad: url)
                    } else {
                        webContent.load(url: url)
                    }
                }
            }
        }
    }
    
    // Perform a search with the given query
    private func performSearch(_ query: String, windowID: ID<WindowState>, chatbot: Bool = false, forceNewTab: Bool = false) {
        if chatbot {
            if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://claude.ai/new?q=\(encodedQuery)") {
                loadURL(searchURL, windowID: windowID, forceNewTab: forceNewTab)
            }
            return
        }
        // Encode query for search URL
        loadURL(SearchEngine.current.urlForQuery(query), windowID: windowID, forceNewTab: forceNewTab)
//        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
//           let searchURL = URL(string: "https://www.google.com/search?q=\(encodedQuery)") {
//            loadURL(searchURL, windowID: windowID)
//        }
    }
    
    // Perform "I'm feeling lucky" search
    private func performImFeelingLucky(_ query: String, windowID: ID<WindowState>, forceNewTab: Bool) {
        if let luckyURL = URL.duckDuckGoLuckyURL(for: query) {
            // Put the search results page in the back stack first, so the user
            // can hit Back if the guess was wrong.
            loadURL(luckyURL, via: SearchEngine.current.urlForQuery(query), windowID: windowID, forceNewTab: forceNewTab)
        }
    }
    
    // Handle direct input that could be a URL or search term
    private func loadQueryOrSearch(_ query: String, windowID: ID<WindowState>, forceNewTab: Bool) {
        // Simple URL detection heuristic
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.contains(" ") {
            // Contains spaces, treat as search
            performSearch(trimmed, windowID: windowID, forceNewTab: forceNewTab)
            return
        }
        
        if trimmed.contains(".") {
            // May be a URL, try to load directly
            let urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: urlString) {
                loadURL(url, windowID: windowID, forceNewTab: forceNewTab)
                return
            }
        }
        
        // Fallback to search
        performSearch(trimmed, windowID: windowID, forceNewTab: forceNewTab)
    }
}
