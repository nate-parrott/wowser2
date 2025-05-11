import Foundation
import SwiftUI

/// Types of actions available in the search overlay
public enum ActionType: CaseIterable {
    case clearAllTabs
    case organizeTabs
    case newNotionDoc
    case newGoogleDoc
    case newGoogleSheet
    case newGoogleSlide
    case newFigmaFile
    
    var title: String {
        switch self {
        case .clearAllTabs:
            return "Clear All Tabs"
        case .organizeTabs:
            return "Organize Tabs"
        case .newNotionDoc:
            return "New Notion Document"
        case .newGoogleDoc:
            return "New Google Document"
        case .newGoogleSheet:
            return "New Google Sheet"
        case .newGoogleSlide:
            return "New Google Slide"
        case .newFigmaFile:
            return "New Figma File"
        }
    }
    
    var parameter: String {
        switch self {
        case .clearAllTabs, .organizeTabs:
            return ""
        case .newNotionDoc:
            return "notion.new"
        case .newGoogleDoc:
            return "doc.new"
        case .newGoogleSheet:
            return "sheet.new"
        case .newGoogleSlide:
            return "slide.new"
        case .newFigmaFile:
            return "figma.new"
        }
    }
    
    var keywords: [String] {
        switch self {
        case .clearAllTabs:
            return ["clear", "close", "tabs", "all tabs", "remove", "delete"]
        case .organizeTabs:
            return ["organize", "tabs", "group", "sort", "arrange"]
        case .newNotionDoc:
            return ["notion", "new", "document", "create", "doc"]
        case .newGoogleDoc:
            return ["google", "new", "document", "create", "doc"]
        case .newGoogleSheet:
            return ["google", "new", "sheet", "spreadsheet", "excel"]
        case .newGoogleSlide:
            return ["google", "new", "slide", "presentation", "powerpoint"]
        case .newFigmaFile:
            return ["figma", "new", "design", "file", "create"]
        }
    }
}

// Extension to provide array of available action items for search
extension BrowserState {
    func availableActions() -> [SearchableItem] {
        return ActionType.allCases.map { action in
            let id = ID<SearchableItem>(raw: "action:\(action.title)")
            let titleStr = NormalizedSearchableString(text: action.title)
            
            return SearchableItem(
                id: id,
                content: .customAction(action.title, action.parameter),
                titleMatchStr: titleStr
            )
        }
    }
    
    func matchingActions(query: String) -> [SearchableItem] {
        let normalizedQuery = query.lowercased()
        
        return ActionType.allCases
            .filter { action in
                // Check if query matches action title or keywords
                action.title.lowercased().contains(normalizedQuery) ||
                action.keywords.contains { keyword in
                    keyword.lowercased().contains(normalizedQuery)
                }
            }
            .map { action in
                let id = ID<SearchableItem>(raw: "action:\(action.title)")
                let titleStr = NormalizedSearchableString(text: action.title)
                
                return SearchableItem(
                    id: id,
                    content: .customAction(action.title, action.parameter),
                    titleMatchStr: titleStr
                )
            }
    }
}

// Extension to handle performing actions
extension BrowserStore {
    func performAction(actionName: String, parameter: String, windowID: ID<WindowState>) {
        // Find which action matches the name
        guard let action = ActionType.allCases.first(where: { $0.title == actionName }) else {
            print("Unknown action: \(actionName)")
            return
        }
        
        // Perform the appropriate action
        switch action {
        case .clearAllTabs:
            clearAllTabs(windowID: windowID)
            
        case .organizeTabs:
            autoOrganizeTabs(in: windowID)
            
        case .newNotionDoc, .newGoogleDoc, .newGoogleSheet, .newGoogleSlide, .newFigmaFile:
            // For new document actions, we open the corresponding URL
            if let url = URL(string: "https://\(parameter)") {
                loadURL(url, windowID: windowID)
            }
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