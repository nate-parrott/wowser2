import SwiftUI

struct Omnibox: View {
    var paneID: ID<WebContent>?
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int
    @ObservedObject var searcher: Searcher
    var fgColor: HSBA?
    var fontSize: CGFloat = 14

    @State private var contentSize: CGSize = .zero
    @State private var focusSnap = FocusSnap()
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID

    /// Non-nil iff the omnibox should hold first responder. Self-derived from
    /// `focusState` — the parent does not drive focus into us.
    private var focusDate: Date? {
        guard let paneID, focusSnap.target == .omnibox(pane: paneID) else { return nil }
        return focusSnap.date
    }

    var body: some View {
        InputTextField(
            text: $searchText,
            options: InputTextFieldOptions(
                placeholder: "Search or enter website name",
                font: .systemFont(ofSize: fontSize, weight: .regular),
                color: fgColor?.uiColor ?? UINSColor.textColor,
                insets: CGSize(width: 8, height: 12 - (fontSize - 14) / 2),
                wantsUpDownArrowEvents: true,
                selectAllOnFocus: true,
                lineLimit: 1
            ),
            focusDate: focusDate,
            focusTarget: paneID.map { FocusTarget.omnibox(pane: $0) },
            onEvent: handleTextFieldEvent,
            contentSize: $contentSize
        )
        .overlay {
            if focusDate == nil {
#if os(macOS)
                WindowDragView(onTapped: activate)
                    .background(Color.white.opacity(0.01))
#endif
            }
        }
        .onReceiveFocusSnap(windowID: windowID) { snap in
//            let wasFocused = self.focusSnap.target == paneID.map { FocusTarget.omnibox(pane: $0) }
            self.focusSnap = snap
//            let nowFocused = snap.target == paneID.map { FocusTarget.omnibox(pane: $0) }
            // On the false→true edge, seed the field with the current URL/title
            // so the user can type-to-replace or Cmd+A to edit.
//            if !wasFocused && nowFocused, let paneID,
//               let pane = BrowserStore.shared.model.pane(forId: paneID) {
//                DispatchQueue.main.async {
//                    searchText = pane.tabAppearance().urlFieldTextSelected
//                }
//            }
        }
    }

    private func handleTextFieldEvent(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter):
            if let windowID, let result = searcher.results.get(selectedResultIndex) {
                BrowserStore.shared.select(result: result, windowID: windowID)
            }
            dismiss()

        case .key(.upArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = max(0, selectedResultIndex - 1)
            }

        case .key(.downArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = min(searcher.results.count - 1, selectedResultIndex + 1)
            }

        case .key(.escape):
            dismiss()

        case .focus:
            guard let paneID else { return }
//            DispatchQueue.main.async {
                BrowserStore.shared.modify { state in
                    state.didFocus(target: .omnibox(pane: paneID))
                }
//            }

        case .blur:
            guard let paneID else { return }
            BrowserStore.shared.modify { state in
                state.didLoseFocus(target: .omnibox(pane: paneID))
            }

        default:
            break
        }
    }

    /// User clicked the omnibox area while it wasn't focused (the drag overlay).
    /// Open the search overlay; the focus snap will pick it up and focus us.
    private func activate() {
        guard let paneID else { return }
        BrowserStore.shared.modify { state in
            state.didFocus(target: .omnibox(pane: paneID))
        }
    }

    private func dismiss() {
        guard let paneID else { return }
        BrowserStore.shared.modify { state in
            state.didLoseFocus(target: .omnibox(pane: paneID))
        }
    }
}
