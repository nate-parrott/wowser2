import SwiftUI
import Combine

/// The per-pane link between the omnibox's input field and its suggestion
/// list. The two render in different places (toolbar field + dropdown on web
/// pages; one centered card on the new-tab page) and never reference each
/// other — both read and act through this object.
///
/// Whether the command bar is open is *not* stored here: that's the focus
/// snap (`FocusTarget.omnibox`), which `PaneView` mirrors in via `setActive`.
@MainActor
final class OmniboxCoordinator: ObservableObject {
    let searcher = Searcher()

    /// What the user has typed. Drives the searcher; resets the selection.
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            searcher.query = text
            selectedIndex = 0
        }
    }
    @Published var selectedIndex = 0
    /// Mirrors "the focus snap says this pane's omnibox is open".
    @Published private(set) var isActive = false

    var paneID: ID<WebContent>?
    var windowID: ID<WindowState>? {
        didSet { searcher.windowID = windowID }
    }
    /// The bottom toolbar (`DefaultsKeys.toolbarAtBottom`) behaves like a chat
    /// box: it opens empty unless asked for the URL, suggestions stack upward
    /// from the field, and typed text defaults to a chat in a side split.
    var atBottom = false {
        didSet { searcher.preferChat = atBottom }
    }

    private var subscriptions = Set<AnyCancellable>()

    init() {
        // Re-render observers when results change.
        searcher.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    var results: [SearchResult] { searcher.results }

    // MARK: - Lifecycle

    /// Opening seeds the field with the page's URL (selected, so typing
    /// replaces it); closing clears it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            let state = BrowserStore.shared.model
            let prefill = !atBottom || (windowID.flatMap { state.windows[$0]?.omniboxPrefillsURL } ?? false)
            text = prefill ? urlFieldText(state: state) : ""
            // The space's folder may have changed since the last keystroke.
            searcher.refreshForEmptyQuery()
        } else {
            text = ""
        }
    }

    private func urlFieldText(state: BrowserState) -> String {
        paneID.flatMap { state.pane(forId: $0) }?.tabAppearance().urlFieldTextSelected ?? ""
    }

    /// The field was clicked while closed: open the command bar. The focus
    /// snap then focuses the field. `prefillURL` seeds it with the page's URL
    /// (the bottom toolbar's site-name button; the top toolbar always does).
    func open(prefillURL: Bool = false) {
        guard let paneID else { return }
        if isActive {
            if prefillURL { text = urlFieldText(state: BrowserStore.shared.model) }
            return
        }
        BrowserStore.shared.modify { state in
            if let windowID = self.windowID {
                state.windows[windowID]?.omniboxPrefillsURL = prefillURL
            }
            state.didFocus(target: .omnibox(pane: paneID))
        }
    }

    func dismiss() {
        guard let windowID else { return }
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.searchOverlayActive = false
        }
    }

    // MARK: - Field events

    func fieldDidFocus() {
        guard let paneID else { return }
        BrowserStore.shared.modify { state in
            state.didFocus(target: .omnibox(pane: paneID))
        }
    }

    func fieldDidBlur() {
        guard let paneID else { return }
        BrowserStore.shared.modify { state in
            state.didLoseFocus(target: .omnibox(pane: paneID))
        }
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        // Bottom toolbar lists suggestions upward: ↑ walks away from the field.
        let delta = atBottom ? -delta : delta
        selectedIndex = min(results.count - 1, max(0, selectedIndex + delta))
    }

    /// Return: run the highlighted suggestion.
    func commitSelection() {
        if let result = results.get(selectedIndex) {
            choose(result)
        } else {
            dismiss()
        }
    }

    func choose(_ result: SearchResult) {
        #if os(macOS)
        if atBottom, let windowID, case .askAgent(let query, _) = result.item.content {
            AgentChatTabs.askInSplit(query: query, windowID: windowID)
            dismiss()
            return
        }
        #endif
        if let windowID {
            BrowserStore.shared.select(result: result, windowID: windowID)
        }
        dismiss()
    }

    /// Escape on an empty new-tab page closes the pane; otherwise it just
    /// closes the command bar.
    func escape() {
        if let paneID, text.isEmpty,
           let pane = BrowserStore.shared.model.pane(forId: paneID),
           pane.info.isEmptyPage {
            BrowserStore.shared.close(webContentId: paneID, removeIfPinned: false)
        } else {
            dismiss()
        }
    }
}
