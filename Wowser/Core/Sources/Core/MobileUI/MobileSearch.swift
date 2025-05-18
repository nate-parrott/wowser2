import SwiftUI

struct MobileSearchOverlay: View {
    @State var searchText: String = ""
    @State var selectedResultIndex: Int = 0
    @StateObject var searcher = Searcher()
    @State private var focusDate: Date?
    
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    var body: some View {
        Color.black.opacity(0.5)
            .edgesIgnoringSafeArea(.all)
            .onTapGesture {
                dismissOverlay()
            }
        
        VStack {
            inputField
            resultsStack
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("Background",  bundle: .module))
                .clipShape(Rectangle())
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 2, y: 3)
        }
        .onAppear {
            focusDate = Date()
            searcher.n = 4
        }
        .onAppearOrChange(of: profileID) { profileID in
            searcher.profileID = profileID
        }
        .onAppearOrChange(of: windowID, perform: { windowID in
            searcher.windowID = windowID
        })
        .onChange(of: searchText) { newValue in
            searcher.query = newValue
            selectedResultIndex = 0 // Reset selection when query changes
        }
        .frame(maxWidth: 320)
        .frame(height: 300, alignment: .top)
        .padding(.bottom, 220) // TODO: use KB height
        .padding(30)
    }
    
    @ViewBuilder private var inputField: some View {
        // Input field
        InputTextField(
            text: $searchText,
            options: InputTextFieldOptions(
                placeholder: "Search or enter website name",
                font: .systemFont(ofSize: 18, weight: .regular),
                insets: CGSize(width: 18, height: 18),
                wantsUpDownArrowEvents: true,
                selectAllOnFocus: true,
                lineLimit: 1
            ),
            focusDate: focusDate,
            onEvent: handleTextFieldEvent
        )
        .frame(height: 54)
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
            
        case .focus: ()
            
        case .blur:
            dismissOverlay()
            break
            
        default:
            break
        }
    }

    
    private func dismissOverlay() {
        BrowserStore.shared.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = false
            }
        }
    }
    
    // Results stack containing all result rows
    private var resultsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(searcher.results.enumerated()), id: \.element.id) { index, result in
                MobileSearchResultRow(
                    result: result,
                    isSelected: index == selectedResultIndex,
                    onSelect: {
                        if let windowID {
                            BrowserStore.shared.select(result: result, windowID: windowID)
                        }
                        dismissOverlay()
                    }
                )
                .id(index)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, searcher.results.count > 0 ? 6 : 0)
    }
}

// Search result row component for displaying a SearchResult
private struct MobileSearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        let (title, subtitle) = titleSubtitle
        
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Icon
                SearchIcon(item: result.item, size: 18, selected: isSelected)
                
                if let title {
                    Text(title + "  ")
                        .font(.system(size: 18))
                        .layoutPriority(2)
                }
                
                Text(subtitle ?? "")
                    .font(.system(size: 18))
                    .layoutPriority(1)
                    .opacity(0.5)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .lineLimit(1)
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected, result: result))
    }
    
    private var titleSubtitle: (String?, String?) {
        let title = result.item.title
        let subtitle = result.item.subtitle
        if title == "" {
            return (subtitle, nil)
        }
        return (title, subtitle)
    }
}
