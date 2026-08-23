import SwiftUI
import Combine

public struct SearchResultsOverlay: View {
    @Binding var searchText: String
    @Binding var selectedResultIndex: Int
    @ObservedObject var searcher: Searcher
    var drawsCenteredBackdropIncludingBehindToolbar: Bool = false
    
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
            
    public var body: some View {
        mainOverlayView
    }
    
    // Main overlay container
    private var mainOverlayView: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.01)
                .opacity(0.01)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    dismissOverlay()
                }
            
            if searcher.results.count > 0 {
                // Search interface
                resultsStack
                    .background {
                        if drawsCenteredBackdropIncludingBehindToolbar {
                            Color.clear
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .padding(.top, -UIConstants.macHeaderHeight - 8)
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color("Background",  bundle: .module))
                                .padding(.top, -10) // remove rounded corners
                                .clipShape(Rectangle())
                                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 2, y: 3)
                        }
                    }
//                    .frame(maxWidth: 500)
//                    .padding(8)
            }
        }
    }

    // Results stack containing all result rows
    private var resultsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(searcher.results.enumerated()), id: \.element.id) { index, result in
                SearchResultRow(
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
        .padding(10)
    }
    
    private func dismissOverlay() {
        BrowserStore.shared.modify { state in
            if let windowID = windowID {
                state.windows[windowID]?.searchOverlayActive = false
            }
        }
    }
}

// Search result row component for displaying a SearchResult
private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        let (title, subtitle) = titleSubtitle
        
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Icon
                SearchIcon(item: result.item, size: 20, selected: isSelected)
                
                if let title {
                    Text(title + "  ")
                        .font(.system(size: 14))
                        .layoutPriority(2)
                }
                
                Text(subtitle ?? "")
                    .font(.system(size: 12))
                    .layoutPriority(1)
                    .opacity(0.5)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .lineLimit(1)
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected, desaturatedHighlight: isDirectToSite))
    }

    private var isDirectToSite: Bool {
        if case .imFeelingLucky = result.item.content { return true }
        return false
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
