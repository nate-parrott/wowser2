import SwiftUI

/// The omnibox's input area: the text field, plus what replaces its text
/// while dictating to the agent or while an attached agent works. Knows
/// nothing about where suggestions render — it talks to the coordinator.
struct OmniboxField: View {
    var paneID: ID<WebContent>?
    @ObservedObject var coordinator: OmniboxCoordinator
    /// Shown while the command bar is closed (the page's host / title).
    var deselectedText: String
    var fgColor: HSBA?
    var fontSize: CGFloat
    /// Whether an agent attached to this window's omnibox is working; its
    /// status replaces the URL while the command bar is closed.
    var hasWorkingAttachedAgent = false

    @Environment(\.windowID) private var windowID
    /// True while a dictation session targeting this pane's omnibox is live.
    @State private var dictationTranscriptShown = false

    private var showsAttachedAgentIndicator: Bool {
        hasWorkingAttachedAgent && !coordinator.isActive && !dictationTranscriptShown
    }

    var body: some View {
        ZStack {
            OmniboxTextField(
                paneID: paneID,
                text: coordinator.isActive ? $coordinator.text : .constant(deselectedText),
                coordinator: coordinator,
                fgColor: fgColor,
                fontSize: fontSize
            )
            .opacity(showsAttachedAgentIndicator || dictationTranscriptShown ? 0 : 1)
            // Hidden-agent indicator replaces the URL while an agent
            // attached to this omnibox is working. Click to reveal.
            if showsAttachedAgentIndicator, let windowID {
                AttachedAgentStatusView(windowID: windowID, fgColor: fgColor, fontSize: fontSize)
            }
            #if os(macOS)
            // Live transcript while dictating into this omnibox (→ agent).
            if dictationTranscriptShown {
                DictationTranscriptView(fgColor: fgColor, fontSize: fontSize)
            }
            #endif
        }
        .modifier(DictationOmniboxHighlightIfAvailable(paneID: paneID, shown: $dictationTranscriptShown))
    }
}

/// The bare text field. Owns first-responder handling (self-derived from the
/// focus snap) and forwards keys to the coordinator.
private struct OmniboxTextField: View {
    var paneID: ID<WebContent>?
    @Binding var text: String
    var coordinator: OmniboxCoordinator
    var fgColor: HSBA?
    var fontSize: CGFloat

    @State private var contentSize: CGSize = .zero
    @State private var focusSnap = FocusSnap()
    @Environment(\.windowID) private var windowID

    /// Non-nil iff the omnibox should hold first responder.
    private var focusDate: Date? {
        guard focusSnap.target == focusTarget else { return nil }
        return focusSnap.date
    }

    private var focusTarget: FocusTarget? {
        if let paneID {
            return .omnibox(pane: paneID)
        }
        if let windowID {
            return .emptyWindowOmnibox(windowID)
        }
        return nil
    }

    var body: some View {
        InputTextField(
            text: $text,
            options: InputTextFieldOptions(
                placeholder: "Search or enter website name",
                font: .systemFont(ofSize: fontSize, weight: .regular),
                color: fgColor?.uiColor ?? UINSColor.textColor,
                insets: CGSize(width: 8, height: 12 - (fontSize - 14) / 2),
                wantsUpDownArrowEvents: true,
                selectAllOnFocus: true,
                lineLimit: 1,
                disableFindReplace: true
            ),
            focusDate: focusDate,
            focusTarget: focusTarget,
            onEvent: handle,
            contentSize: $contentSize
        )
        .overlay {
            if focusDate == nil {
#if os(macOS)
                WindowDragView(onTapped: coordinator.open)
                    .background(Color.white.opacity(0.01))
#endif
            }
        }
        .onReceiveFocusSnap(windowID: windowID) { focusSnap = $0 }
    }

    private func handle(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter): coordinator.commitSelection()
        case .key(.upArrow): coordinator.moveSelection(by: -1)
        case .key(.downArrow): coordinator.moveSelection(by: 1)
        case .key(.escape): coordinator.escape()
        case .focus: coordinator.fieldDidFocus()
        case .blur: coordinator.fieldDidBlur()
        default: break
        }
    }
}
