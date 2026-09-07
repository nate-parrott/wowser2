import Foundation

public enum SelectorPickerMode: String, Equatable, Codable {
    /// Plain CSS selectors only.
    case normal
    /// Also generates synthetic computed-style selectors (`.__sss__...`). Not valid
    /// CSS — resolve with `AugmentedSelector.matchesJS(for:)`.
    case augmented
}

public struct SelectorPickerSession: Equatable, Codable {
    public var paneId: ID<WebContent>
    public var mode: SelectorPickerMode

    public init(paneId: ID<WebContent>, mode: SelectorPickerMode) {
        self.paneId = paneId
        self.mode = mode
    }
}

public extension BrowserState {
    /// Begin picking a selector in the focused pane of `tabID`. No-op if the tab
    /// isn't in a window.
    mutating func startSelectorPicker(tabID: ID<Tab>, mode: SelectorPickerMode) {
        guard let tab = tabs[tabID],
              let pane = tab.panes[min(tab.focusedPaneIdx, tab.panes.count - 1)],
              let window = windowContaining(tabId: tabID) else { return }
        windows[window.id]?.selectorPicker = SelectorPickerSession(paneId: pane.id, mode: mode)
    }

    /// Cancel an active picker in `windowID`. Returns whether there was one.
    @discardableResult
    mutating func cancelSelectorPicker(windowID: ID<WindowState>) -> Bool {
        guard windows[windowID]?.selectorPicker != nil else { return false }
        windows[windowID]?.selectorPicker = nil
        return true
    }
}
