import SwiftUI

/// The new-tab page's centered command bar: the omnibox field with the
/// suggestion list directly beneath it, on one shared card. (On web pages the
/// same two pieces are split between `ToolbarView` and `OmniboxDropdown`.)
struct NewTabCommandBar: View {
    var paneID: ID<WebContent>?
    @ObservedObject var coordinator: OmniboxCoordinator

    private var showsSuggestions: Bool {
        coordinator.isActive && !coordinator.results.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if showsSuggestions {
                OmniboxSuggestionList(coordinator: coordinator)
            }
        }
        .background {
            if showsSuggestions {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, -8)
            }
        }
        // Dictation-to-agent outline around the whole card.
        .overlay {
            Color.clear
                .modifier(DictationCardHighlightIfAvailable(paneID: paneID, cornerRadius: 10))
                .padding(.top, showsSuggestions ? -8 : 0)
                .allowsHitTesting(false)
        }
    }

    private var inputRow: some View {
        HStack(spacing: -2) {
            LeadingIcon(isSecure: nil, iconOverride: "magnifyingglass")
                .padding(.leading, 12)
                .padding(.trailing, 4)
            OmniboxField(paneID: paneID, coordinator: coordinator, deselectedText: "", fontSize: 14)
            #if os(macOS)
            WithSnapshotMain(store: BrowserStore.shared, snapshot: { !$0.toolbarConfig.hidden.contains(.builtin(.dictation)) }) { dictationShown in
                if dictationShown {
                    DictationButton(paneID: paneID, emptyPage: true)
                }
            }
            #endif
            Spacer().frame(width: 20)
        }
        .frame(height: UIConstants.macHeaderHeight)
        .contentShape(Rectangle())
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.1), radius: 12, x: 0, y: 0)
    }
}
