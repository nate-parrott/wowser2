import Foundation
import SwiftUI

/// Types of search actions available in the search overlay
public enum SearchAction: Equatable, Codable {
    case clearAllTabs
    case organizeTabs
    case separateSplitTabs
    case openURL(URL)

    // Predefined URL cases
    static let newNotionDoc = openURL(URL(string: "https://notion.new")!)
    static let newGoogleDoc = openURL(URL(string: "https://doc.new")!)
    static let newGoogleSheet = openURL(URL(string: "https://sheet.new")!)
    static let newGoogleSlide = openURL(URL(string: "https://slide.new")!)
    static let newFigmaFile = openURL(URL(string: "https://figma.new")!)
    
//    // All available actions including predefined URL cases
//    public static var allDefaultActions: [SearchAction] = {
//        return [
//
//        ]
//    }()
    
    var title: String {
        switch self {
        case .clearAllTabs:
            return "Clear all tabs"
        case .organizeTabs:
            return "Organize tabs"
        case .separateSplitTabs:
            return "Separate split tabs"
        case SearchAction.newNotionDoc:
            return "New Notion page"
        case SearchAction.newGoogleDoc:
            return "New Google Doc"
        case SearchAction.newGoogleSheet:
            return "New Google Sheet"
        case SearchAction.newGoogleSlide:
            return "New Google Slides document"
        case SearchAction.newFigmaFile:
            return "New Figma file"
        case .openURL(let url):
            if let key = NativePageKey(url: url) {
                switch key {
                case .terminal(_, let cmd):
                    if cmd == "claude" { return "New Claude" }
                    return "Open Terminal"
                case .vscode: return "Open VS Code"
                case .fileBrowser: return "Open File Browser"
                }
            }
            return "Open \(url.stripped)" // not expected
        }
    }
    
    // Keywords are empty for now as requested
    var keywords: [String] {
        return []
    }
}

// Extension to provide array of available action items for search
extension BrowserState {
    private static var staticActionItems: [SearchableItem] = {
        // For native-page actions, the URL itself encodes a fresh session id;
        // we generate it lazily per-match in matchingActions to avoid handing
        // out the same id across every search.
        let actions: [SearchAction] = [
            .clearAllTabs,
            .organizeTabs,
            .newNotionDoc,
            .newGoogleDoc,
            .newGoogleSheet,
            .newGoogleSlide,
            .newFigmaFile,
        ]
        return actions.map { action in
            let id = ID<SearchableItem>(raw: "action:\(action.title)")
            let titleStr = NormalizedSearchableString(text: action.title)

            return SearchableItem(
                id: id,
                content: .searchAction(action),
                titleMatchStrings: [titleStr]
            )
        }
    }()

    private static func dynamicActions(state: BrowserState, windowID: ID<WindowState>?) -> [SearchableItem] {
        // Seed new native tabs with the folder of the most recently used
        // native tab in this profile/space — so opening a new terminal,
        // VS Code window, or file browser lands in the same place the user
        // was working.
        let suggestedFolder = state.mostRecentNativeFolderPath(windowID: windowID)
        let filesPath = suggestedFolder ?? FileManager.default.homeDirectoryForCurrentUser.path

        let terminalAction = SearchAction.openURL(NativePageKey.terminal(cwd: suggestedFolder, runCommand: nil).url)
        let terminalItem = SearchableItem(
            id: ID<SearchableItem>(raw: "action:Open Terminal"),
            content: .searchAction(terminalAction),
            titleMatchStrings: [
                NormalizedSearchableString(text: "Open Terminal"),
                NormalizedSearchableString(text: "Terminal"),
                NormalizedSearchableString(text: "Console"),
            ]
        )

        let vscodeAction = SearchAction.openURL(NativePageKey.vscode(folder: suggestedFolder).url)
        let vscodeItem = SearchableItem(
            id: ID<SearchableItem>(raw: "action:Open VS Code"),
            content: .searchAction(vscodeAction),
            titleMatchStrings: [
                NormalizedSearchableString(text: "Open VS Code"),
                NormalizedSearchableString(text: "VS Code"),
                NormalizedSearchableString(text: "Visual Studio Code"),
                NormalizedSearchableString(text: "Editor"),
            ]
        )

        let filesAction = SearchAction.openURL(NativePageKey.fileBrowser(path: filesPath).url)
        let filesItem = SearchableItem(
            id: ID<SearchableItem>(raw: "action:Open File Browser"),
            content: .searchAction(filesAction),
            titleMatchStrings: [
                NormalizedSearchableString(text: "Open File Browser"),
                NormalizedSearchableString(text: "Files"),
                NormalizedSearchableString(text: "Finder"),
                NormalizedSearchableString(text: "Browse Files"),
            ]
        )

        let claudeAction = SearchAction.openURL(NativePageKey.terminal(cwd: suggestedFolder, runCommand: "claude").url)
        let claudeItem = SearchableItem(
            id: ID<SearchableItem>(raw: "action:Claude Code"),
            content: .searchAction(claudeAction),
            titleMatchStrings: [
                NormalizedSearchableString(text: "Claude Code"),
                NormalizedSearchableString(text: "New Claude"),
                NormalizedSearchableString(text: "claude"),
                NormalizedSearchableString(text: "Agent"),
            ]
        )

        var items = [terminalItem, vscodeItem, filesItem, claudeItem]

        // 'Separate split tabs' is only relevant when the active tab has > 1 pane.
        if let windowID,
           let currentTabID = state.windows[windowID]?.currentTab,
           let currentTab = state.tabs[currentTabID],
           currentTab.panes.count > 1 {
            let action = SearchAction.separateSplitTabs
            items.append(SearchableItem(
                id: ID<SearchableItem>(raw: "action:\(action.title)"),
                content: .searchAction(action),
                titleMatchStrings: [
                    NormalizedSearchableString(text: action.title),
                    NormalizedSearchableString(text: "split"),
                    NormalizedSearchableString(text: "unsplit"),
                ]
            ))
        }
        return items
    }

    func matchingActions(query: NormalizedSearchableString, windowID: ID<WindowState>? = nil) -> [SearchableItem] {
        let all = BrowserState.staticActionItems + BrowserState.dynamicActions(state: self, windowID: windowID)
        return all.filter { action in
            action.matchQuality(query: query) != .none
        }
    }
}

// Extension to handle performing actions
extension BrowserStore {
    func performSearchAction(action: SearchAction, windowID: ID<WindowState>) {
        switch action {
        case .clearAllTabs:
            clearAllTabs(windowID: windowID)
            
        case .organizeTabs:
            Task {
                await autoOrganizeTabs(in: windowID)
            }

        case .separateSplitTabs:
            modify { state in
                if let tabID = state.windows[windowID]?.currentTab {
                    state.separateSplitTabs(tabId: tabID)
                }
            }

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

// MARK: - SearchableItem UI Extensions

extension SearchableItem {
    /// Gets the user-friendly title for display in search results
    public var title: String {
        if let representsNativeKey {
            switch representsNativeKey {
            case .terminal(let cwd, _):
                if let cwd {
                    return cwd.lastPathComponent
                }
            case .vscode(let folder):
                if let folder {
                    return folder.lastPathComponent
                }
            case .fileBrowser(let path):
                if let path {
                    return path.lastPathComponent
                }
            }
        }
        switch content {
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
        case .tab(_, let info):
            return info.title ?? info.url?.stripped ?? "Tab"
        case .searchAction(let action):
            return action.title
        }
    }
    
    /// Gets the user-friendly subtitle for display in search results
    public var subtitle: String? {
        if let representsNativeKey {
            switch representsNativeKey {
            case .terminal(let cwd, _):
                if let cwd {
                    return "Terminal in \(cwd)"
                }
            case .vscode(let folder):
                if let folder {
                    return "VS Code in \(folder)"
                }
            case .fileBrowser(let path):
                if let path {
                    return "Files in \(path)"
                }
            }
        }
        switch content {
        case .searchWhatYouTyped:
            return nil
        case .urlYouTyped(let url):
            return url.absoluteString
        case .searchSuggestion:
            return nil
        case .imFeelingLucky:
            return "Direct to Website"
        case .chatbot:
            return "Chat"
        case .historyItem(let item):
            return item.url.displayString
        case .tab(_, _):
            return "Switch to Tab"
        case .searchAction:
            return "Action"
        }
    }
    
    private var representsNativeKey: NativePageKey? {
        switch content {
        case .searchWhatYouTyped:
            return nil
        case .urlYouTyped(let url):
            return NativePageKey(url: url)
        case .searchSuggestion:
            return nil
        case .imFeelingLucky:
            return nil
        case .chatbot:
            return nil
        case .historyItem(let item):
            return NativePageKey(url: item.url)
        case .tab(_, _):
            return nil
        case .searchAction:
            return nil
        }
    }
}
