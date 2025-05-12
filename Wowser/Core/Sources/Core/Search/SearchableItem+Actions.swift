import Foundation
import SwiftUI

/// Types of search actions available in the search overlay
public enum SearchAction: CaseIterable {
    case clearAllTabs
    case organizeTabs
    case openURL(URL)
    
    // Predefined URL cases
    static let newNotionDoc = openURL(URL(string: "https://notion.new")!)
    static let newGoogleDoc = openURL(URL(string: "https://doc.new")!)
    static let newGoogleSheet = openURL(URL(string: "https://sheet.new")!)
    static let newGoogleSlide = openURL(URL(string: "https://slide.new")!)
    static let newFigmaFile = openURL(URL(string: "https://figma.new")!)
    
    // All available actions including predefined URL cases
    public static var allCases: [SearchAction] {
        return [
            .clearAllTabs,
            .organizeTabs,
            .newNotionDoc,
            .newGoogleDoc,
            .newGoogleSheet, 
            .newGoogleSlide,
            .newFigmaFile
        ]
    }
    
    var title: String {
        switch self {
        case .clearAllTabs:
            return "Clear All Tabs"
        case .organizeTabs:
            return "Organize Tabs"
        case .openURL(let url):
            // Handle specific predefined URLs
            if self == SearchAction.newNotionDoc {
                return "New Notion Document"
            } else if self == SearchAction.newGoogleDoc {
                return "New Google Document"
            } else if self == SearchAction.newGoogleSheet {
                return "New Google Sheet"
            } else if self == SearchAction.newGoogleSlide {
                return "New Google Slide"
            } else if self == SearchAction.newFigmaFile {
                return "New Figma File"
            } else {
                return "Open \(url.host ?? url.absoluteString)"
            }
        }
    }
    
    // Keywords are empty for now as requested
    var keywords: [String] {
        return []
    }
}

// Extension to provide array of available action items for search
extension BrowserState {
    func availableActions() -> [SearchableItem] {
        return SearchAction.allCases.map { action in
            let id = ID<SearchableItem>(raw: "action:\(action.title)")
            let titleStr = NormalizedSearchableString(text: action.title)
            
            return SearchableItem(
                id: id,
                content: .searchAction(action),
                titleMatchStr: titleStr
            )
        }
    }
    
    func matchingActions(query: String) -> [SearchableItem] {
        let normalizedQuery = query.lowercased()
        
        return SearchAction.allCases
            .filter { action in
                // Check if query matches action title
                action.title.lowercased().contains(normalizedQuery)
            }
            .map { action in
                let id = ID<SearchableItem>(raw: "action:\(action.title)")
                let titleStr = NormalizedSearchableString(text: action.title)
                
                return SearchableItem(
                    id: id,
                    content: .searchAction(action),
                    titleMatchStr: titleStr
                )
            }
    }
}

// Extension to handle performing actions
extension BrowserStore {
    func performAction(action: SearchAction, windowID: ID<WindowState>) {
        switch action {
        case .clearAllTabs:
            clearAllTabs(windowID: windowID)
            
        case .organizeTabs:
            autoOrganizeTabs(in: windowID)
            
        case .openURL(let url):
            loadURL(url, windowID: windowID)
        }
    }
    
    private func clearAllTabs(windowID: ID<WindowState>) {
        modify { state in
            guard let window = state.windows[windowID] else { return }
            
            // Get a list of all tab IDs in the window
            let tabIDs = window.tabs
            
            // Keep track of web content IDs to close
            var webContentIDs = [ID<WebContent>]()
            
            // Collect all web content IDs from all tabs
            for tabID in tabIDs {
                guard let tab = state.tabs[tabID] else { continue }
                
                for pane in tab.panes {
                    webContentIDs.append(pane.id)
                }
            }
            
            // Create a new empty tab
            let newTab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init())])
            let location = state.insertionIndex(window: windowID, spawningTabId: nil)
            state.insertTab(newTab, location: location, inWindow: windowID)
            state.activate(tabId: newTab.id, in: windowID)
            
            // Then close all the old web contents
            DispatchQueue.main.async {
                for webContentID in webContentIDs {
                    self.close(webContentId: webContentID, removeIfPinned: false)
                }
            }
        }
    }
    
    private func loadURL(_ url: URL, windowID: ID<WindowState>) {
        modify { state in
            if let currentTabId = state.windows[windowID]?.currentTab,
               let tab = state.tabs[currentTabId],
               let pane = tab.panes[tab.focusedPaneIdx],
               pane.info.isEmptyPage {
                
                // If current tab is empty, use it
                state.modifyPaneAndTab(forWebContentId: pane.id) { pane, _ in
                    pane.info = WebContent.Info(url: url)
                }
                
                DispatchQueue.main.async {
                    if let webContent = self.getOrCreateWebContent(forId: pane.id, toBeActiveInWindow: windowID) {
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
}