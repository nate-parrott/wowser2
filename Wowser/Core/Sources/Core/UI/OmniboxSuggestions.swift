import SwiftUI

/// The omnibox's suggestion rows. Placement and backdrop are the caller's
/// business (`OmniboxDropdown` on web pages, `NewTabCommandBar` on the
/// new-tab page); selection and picking go through the coordinator.
struct OmniboxSuggestionList: View {
    @ObservedObject var coordinator: OmniboxCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(coordinator.results.enumerated()), id: \.element.id) { index, result in
                SearchResultRow(
                    result: result,
                    isSelected: index == coordinator.selectedIndex,
                    onSelect: { coordinator.choose(result) }
                )
                .id(index)
            }
        }
        .padding(10)
    }
}

/// Web-page placement: a card hanging under the toolbar.
struct OmniboxDropdown: View {
    @ObservedObject var coordinator: OmniboxCoordinator

    var body: some View {
        if !coordinator.results.isEmpty {
            OmniboxSuggestionList(coordinator: coordinator)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color("Background", bundle: .module))
                        .padding(.top, -10) // square off the top corners
                        .clipShape(Rectangle())
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 2, y: 3)
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
                        .font(.system(size: result.item.isTerminalStyled ? 13 : 14, design: result.item.isTerminalStyled ? .monospaced : .default))
                        .layoutPriority(2)
                }
                
                Text(subtitle ?? "")
                    .font(.system(size: 12))
                    .layoutPriority(1)
                    .opacity(0.5)
                    .padding(.leading, -6)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .lineLimit(1)
        }
        .buttonStyle(SearchResultButtonStyle(isHighlighted: isSelected, desaturatedHighlight: isDirectToSite, highlightColor: result.item.isTerminalStyled ? .black : nil))
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
