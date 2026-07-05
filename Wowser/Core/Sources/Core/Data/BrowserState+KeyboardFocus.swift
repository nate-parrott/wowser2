import Foundation

// All keyboard-focus / first-responder logic for the app lives in this file.
// Views never compute their own "should I be focused?" predicate — they
// observe `BrowserState.focusState(windowID:)` and react if its `target`
// matches their case. See CLAUDE.md for the full contract.

public enum FocusTarget: Equatable {
    case webContent(ID<WebContent>)
    case terminal(ID<WebContent>)
    case fileBrowser(ID<WebContent>)
    case reader(ID<WebContent>)
    case findInPage(ID<WebContent>)
    case omnibox(pane: ID<WebContent>)
    case emptyWindowOmnibox(ID<WindowState>) // when no tab is selected
    case spaceTitle(profile: ID<Profile>, window: ID<WindowState>) // editable sidebar space-name field

    public var paneID: ID<WebContent>? {
        switch self {
        case .webContent(let id), .terminal(let id), .fileBrowser(let id),
             .reader(let id), .findInPage(let id), .omnibox(pane: let id):
            return id
        case .emptyWindowOmnibox, .spaceTitle: return nil
        }
    }

    func windowID(state: BrowserState) -> ID<WindowState>? {
        if let paneID {
            return state.windowContaining(webContentId: paneID)?.id
        }
        switch self {
        case .webContent, .terminal, .fileBrowser, .reader, .findInPage, .omnibox:
            assertionFailure()
            return nil
        case .emptyWindowOmnibox(let winID):
            return winID
        case .spaceTitle(_, let winID):
            return winID
        }
    }
}

public struct FocusSnap: Equatable {
    public var target: FocusTarget?
    /// Bumped when the window becomes key. Surfaces re-focus events even when `target` hasn't changed.
    public var date: Date?

    fileprivate static var midChangeFocus = false
}

extension BrowserState {
    /// Call this from a view's first-responder-gained handler. Reconciles the
    /// underlying state flags (`searchOverlayActive`, `findInPageActiveInPaneId`,
    /// `focusedPaneIdx`) so that `focusState` will return this exact target.
    public mutating func didFocus(target: FocusTarget) {
        if FocusSnap.midChangeFocus { return }
        guard let windowID = target.windowID(state: self) else { return }

        if let paneID = target.paneID {
            modifyPaneAndTab(forWebContentId: paneID) { _, tab in
                if let idx = tab.panes.elements.firstIndex(where: { $0.id == paneID }) {
                    tab.focusedPaneIdx = idx
                }
            }
        }

        // Mutually-exclusive mode flags. Any target that isn't omnibox clears
        // searchOverlayActive; any target that isn't findInPage clears the
        // find-in-page pane id. This keeps focusState's switch unambiguous.
        switch target {
        case .omnibox:
            windows[windowID]?.searchOverlayActive = true
            windows[windowID]?.findInPageActiveInPaneId = nil
        case .findInPage:
            windows[windowID]?.searchOverlayActive = false
            windows[windowID]?.findInPageActiveInPaneId = target.paneID
        case .webContent, .terminal, .fileBrowser, .reader:
            windows[windowID]?.searchOverlayActive = false
            windows[windowID]?.findInPageActiveInPaneId = nil
        case .spaceTitle(let profileID, _):
            windows[windowID]?.searchOverlayActive = false
            windows[windowID]?.findInPageActiveInPaneId = nil
            windows[windowID]?.editingSpaceTitleForProfile = profileID
        case .emptyWindowOmnibox: () // no op
        }

        // Any target other than spaceTitle ends space-title editing.
        switch target {
        case .spaceTitle: ()
        case .omnibox, .findInPage, .webContent, .terminal, .fileBrowser, .reader, .emptyWindowOmnibox:
            windows[windowID]?.editingSpaceTitleForProfile = nil
        }
    }

    /// Call this from a view's first-responder-lost handler. Only mutates state
    /// if `target` is currently the focus target — guards against blurs that
    /// arrive after focus has already moved elsewhere.
    public mutating func didLoseFocus(target: FocusTarget) {
        if FocusSnap.midChangeFocus { return }
        if !isTargetFocused(target) { return }
        guard let windowID = target.windowID(state: self) else {
            return
        }
//        let paneID = target.paneID
//        guard let windowID = windowContaining(webContentId: paneID)?.id else { return }

        switch target {
        case .omnibox:
            windows[windowID]?.searchOverlayActive = false
        case .findInPage:
            windows[windowID]?.findInPageActiveInPaneId = nil
        case .spaceTitle:
            windows[windowID]?.editingSpaceTitleForProfile = nil
        case .webContent, .terminal, .fileBrowser, .reader, .emptyWindowOmnibox:
            () // Whatever takes focus next will reassert via didFocus.
        }
    }

    /// Single source of truth: which UI element should hold first responder
    /// for this window right now. Pure function of state.
    public func focusState(windowID: ID<WindowState>) -> FocusSnap {
        guard let window = windows[windowID] else {
            return .init(target: .emptyWindowOmnibox(windowID), date: windows[windowID]?.lastBecameKeyAt)
        }
        let date = window.lastBecameKeyAt

        // Editing a space (profile) title in the sidebar. A deliberately-opened
        // omnibox still wins; otherwise the title field holds focus regardless
        // of whether a tab is selected.
        if !window.searchOverlayActive, let profileID = window.editingSpaceTitleForProfile {
            return .init(target: .spaceTitle(profile: profileID, window: windowID), date: date)
        }

        guard let tabID = window.currentTab,
              let tab = tabs[tabID],
              let pane = tab.panes.elements.get(tab.focusedPaneIdx)
        else {
            return .init(target: .emptyWindowOmnibox(windowID), date: date)
        }
        let paneID = pane.id

        // Priority order — the first match wins:
        // 1. Omnibox is open (user opened it deliberately, or the pane is empty so it auto-opens).
        if window.searchOverlayActive || pane.info.isEmptyPage {
            return .init(target: .omnibox(pane: paneID), date: date)
        }
        // 2. Find-in-page bar is up on this pane.
        if window.findInPageActiveInPaneId == paneID {
            return .init(target: .findInPage(paneID), date: date)
        }
        // 3. Native overlay (terminal / file browser). VSCode is rendered by a
        //    child WKWebView so it's treated as ordinary web content here.
        if let url = pane.info.url, let key = NativePageKey(url: url) {
            switch key {
            case .terminal:
                return .init(target: .terminal(paneID), date: date)
            case .fileBrowser:
                return .init(target: .fileBrowser(paneID), date: date)
            case .vscode:
                () // fall through — vscode is a normal webview; the loading
                   // sentinel page also takes ordinary web focus.
            }
        }
        // 4. Reader overlay is showing on this pane.
        if pane.info.readerAvailable == true {
            return .init(target: .reader(paneID), date: date)
        }
        // 5. Default: the page's WKWebView.
        return .init(target: .webContent(paneID), date: date)
    }

    public func isTargetFocused(_ target: FocusTarget) -> Bool {
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
    /// Take first responder as the given FocusTarget. ALWAYS use this — never
    /// raw `becomeFirstResponder` / `makeFirstResponder` — when reacting to an
    /// observed FocusSnap. Suppresses the resulting focus callback so it
    /// doesn't loop back into `didFocus` (the caller already encodes the
    /// desired state).
    public func wowser_becomeFirstResponder(asTarget target: FocusTarget, canDeferOneFrame: Bool = true) {
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

    /// True if `responder` is `self` or a descendant view of `self`.
    public func wowser_subtreeContains(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        var current: NSView? = view
        while let cur = current {
            if cur === self { return true }
            current = cur.superview
        }
        return false
    }
}

#endif
