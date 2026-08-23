#if os(macOS)
import SwiftUI

/// The toolbar microphone. Its glyph tells you where dictation will go:
/// filled when a text field on the page is focused (dictate into it), outlined
/// when it would go to the agent via the omnibox. Hovering previews the target
/// outline; clicking starts (or commits) a session. ⌘D does the same.
struct DictationButton: View {
    var paneID: ID<WebContent>?
    /// The larger, new-tab-page variant.
    var emptyPage: Bool
    var fgColor: HSBA?

    @Environment(\.windowID) private var windowID
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Bool in
            guard let paneID, let pane = state.pane(forId: paneID) else { return false }
            if let url = pane.info.url, NativePageKey(url: url)?.isTerminal == true { return true }
            return pane.info.focusedEditable != nil && !pane.info.isEmptyPage
        }) { fieldFocused in
            Button(action: toggle) {
                Image(systemName: symbol(fieldFocused: fieldFocused))
                    .imageScale(emptyPage ? .large : .medium)
                    .foregroundStyle(isActiveForThisPane ? Color.red : (fgColor?.color ?? Color.primary))
                    .opacity(isActiveForThisPane ? 1 : (emptyPage ? 0.4 : (fieldFocused ? 0.85 : 0.6)))
                    .frame(width: emptyPage ? 34 : 30, height: emptyPage ? 34 : 30)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(helpText(fieldFocused: fieldFocused))
            .onHover { hovering in
                controller.setHoverPreview(paneID: paneID, windowID: windowID, hovering: hovering)
            }
            .offset(x: emptyPage ? 10 : 0)
        }
    }

    private var isActiveForThisPane: Bool {
        controller.isActive && controller.target?.paneID == paneID
    }

    private func symbol(fieldFocused: Bool) -> String {
        if isActiveForThisPane { return "mic.fill" }
        if emptyPage { return "mic" }
        return fieldFocused ? "mic.fill" : "mic"
    }

    private func helpText(fieldFocused: Bool) -> String {
        if isActiveForThisPane { return "Finish dictating (⌘D or Return; Esc to cancel)" }
        if fieldFocused { return "Dictate into the focused text field or terminal (⌘D)" }
        return "Dictate a question for the agent (⌘D)"
    }

    private func toggle() {
        guard let windowID else { return }
        controller.toggle(paneID: paneID, windowID: windowID)
    }
}
#endif
