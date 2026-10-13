import SwiftUI

extension View {
    /// Apply to a vertical `ScrollView`: shows a divider along the top edge
    /// when content is scrolled out of view above, and along the bottom edge
    /// when there's more content below.
    func scrollEdgeDividers(horizontalPadding: CGFloat = 0) -> some View {
        modifier(ScrollEdgeDividers(horizontalPadding: horizontalPadding))
    }
}

private struct ScrollEdgeDividers: ViewModifier {
    var horizontalPadding: CGFloat

    @State private var edges = ScrolledEdges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrolledEdges.self) { geo in
                let visible = geo.visibleRect
                return ScrolledEdges(
                    contentAbove: visible.minY > 1,
                    contentBelow: visible.maxY < geo.contentSize.height - 1
                )
            } action: { _, new in
                edges = new
            }
            .overlay(alignment: .top) {
                if edges.contentAbove {
                    Divider().padding(.horizontal, horizontalPadding)
                }
            }
            .overlay(alignment: .bottom) {
                if edges.contentBelow {
                    Divider().padding(.horizontal, horizontalPadding)
                }
            }
    }
}

private struct ScrolledEdges: Equatable {
    var contentAbove = false
    var contentBelow = false
}
