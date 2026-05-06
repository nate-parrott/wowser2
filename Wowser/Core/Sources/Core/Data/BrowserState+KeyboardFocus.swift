import Foundation

enum FocusTarget: Equatable {
    case webContent(ID<WebContent>)
    case terminal(ID<WebContent>)
    case fileBrowser(ID<WebContent>)
    case omnibox(pane: ID<WebContent>)
}

struct FocusSnap: Equatable {
    var target: FocusTarget?
    var date: Date?
    
    fileprivate static var midChangeFocus = false
}

extension BrowserState {
    // Updates the focus state IF this was not manually triggered
    mutating func didFocus(target: FocusTarget) {
        if FocusSnap.midChangeFocus {
            return
        }
        
        func focusMainContent(paneID: ID<WebContent>) {
            if let windowID = windowContaining(webContentId: paneID)?.id {
                windows[windowID]?.searchOverlayActive = false
                modifyPaneAndTab(forWebContentId: paneID) { pane, tab in
                    tab.focusedPaneIdx = tab.panes.elements.firstIndex(where: { $0.id == paneID }) ?? 0
                }
            }
        }
        
        switch target {
        case .webContent(let id):
            focusMainContent(paneID: id)
        case .terminal(let id):
            focusMainContent(paneID: id)
        case .fileBrowser(let id):
            focusMainContent(paneID: id)
        case .omnibox(let id):
            if let windowID = windowContaining(webContentId: id)?.id {
                windows[windowID]?.searchOverlayActive = true
                modifyPaneAndTab(forWebContentId: id) { pane, tab in
                    tab.focusedPaneIdx = tab.panes.elements.firstIndex(where: { $0.id == id }) ?? 0
                }
            }
        }
    }
    
    func focusState(windowID: ID<WindowState>) -> FocusSnap {
        if let window = windows[windowID],
            let tabID = window.currentTab,
            let tab = tabs[tabID],
            let pane = tab.panes.elements.get(tab.focusedPaneIdx)
        {
            if window.searchOverlayActive {
                return .init(target: .omnibox(pane: pane.id), date: window.lastBecameKeyAt)
            }
            if let url = pane.info.url,
               let key = NativePageKey(url: url) {
                switch key {
                case .terminal(let id, let cwd):
                    return .init(target: .terminal(pane.id), date: window.lastBecameKeyAt)
                case .vscode: () // fall thru to focus webcontent
                case .fileBrowser:
                    return .init(target: .fileBrowser(pane.id), date: window.lastBecameKeyAt)
                }
            }
            return .init(target: .webContent(pane.id), date: window.lastBecameKeyAt)
        }
    }
    
    func isTargetFocused(_ target: FocusTarget) -> Bool {
        for id in windows.keys {
            if focusState(windowID: id).target == target {
                return true
            }
        }
        return false
    }
}

#if os(macOS)
import AppKit

extension NSView {
    // MUST use this when implementing focus targeting. NEVER use normal becomeFirstResponder when focusing based on focus state observation
    func wowser_becomeFirstResponder(asTarget target: FocusTarget, canDeferOneFrame: Bool = true) {
        if let window {
            FocusSnap.midChangeFocus = true
            window.makeFirstResponder(self)
            FocusSnap.midChangeFocus = false
        } else if canDeferOneFrame {
            DispatchQueue.main.async { [weak self] in
                if BrowserStore.shared.model.isTargetFocused(target) {
                    self?.wowser_becomeFirstResponder(asTarget: target, canDeferOneFrame: false)
                }
            }
        }
    }
}

#endif
