import SwiftUI

struct Omnibox: View {
    var focusDate: Date?
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int
    @ObservedObject var searcher: Searcher
    var fgColor: HSBA?
    var onFocus: () -> Void // Handler should focus this pane within its tab and set searchOverlay visible on the pane state.
    
    @State private var contentSize: CGSize = .zero
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        // Input field
        InputTextField(
            text: $searchText,
            options: InputTextFieldOptions(
                placeholder: "Search or enter website name",
                font: .systemFont(ofSize: 14, weight: .regular),
                color: fgColor?.uiColor ?? UINSColor.textColor,
                insets: CGSize(width: 16, height: 12),
                wantsUpDownArrowEvents: true,
                selectAllOnFocus: true,
                lineLimit: 1
            ),
            focusDate: focusDate,
            onEvent: handleTextFieldEvent,
            contentSize: $contentSize
        )
        .overlay {
            if focusDate == nil {
#if os(macOS)
                WindowDragView(onTapped: onFocus)
                    .background(Color.white.opacity(0.01))
//                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onEnded({ _ in
//                        print("DRAG!")
//                    }))
//                    .onTapGesture {
//                        onFocus()
//                    }
#endif
            }
        }
    }
    
    // Handle text field events
    private func handleTextFieldEvent(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter):
            if let windowID, let result = searcher.results.get(selectedResultIndex) {
                BrowserStore.shared.select(result: result, windowID: windowID)
            }
            dismissOverlay()
            
        case .key(.upArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = max(0, selectedResultIndex - 1)
            }
            
        case .key(.downArrow):
            if !searcher.results.isEmpty {
                selectedResultIndex = min(searcher.results.count - 1, selectedResultIndex + 1)
            }
            
        case .key(.escape):
            dismissOverlay()
            
        case .focus:
            onFocus()
            
        case .blur:
            dismissOverlay()
            break
            
        default:
            break
        }
    }
        
    // Dismiss the search overlay
    private func dismissOverlay() {
        BrowserStore.shared.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = false
            }
        }
    }
}
