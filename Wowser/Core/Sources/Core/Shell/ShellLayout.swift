import SwiftUI

// Layout building blocks for the shell renderer.
//
// Rows and columns are plain HStack / VStack. Two small custom layouts cover
// what stacks can't express directly:
//
//  - `ShellSizeLayout` gives one node CSS-like sizing: fixed size, min / max
//    as *caps* (a SwiftUI flexible frame with only `maxWidth` set would grow
//    to that max), and "fill".
//  - `ShellStackLayout` is a ZStack whose children can each pick where they
//    sit (`alignSelf`).

enum ShellAxis {
    case row
    case column
    case stack
}

extension EnvironmentValues {
    /// The axis of the box this node is a child of.
    @Entry var shellAxis: ShellAxis = .stack
    /// The parent box has `align: "stretch"`: fill its cross axis.
    @Entry var shellStretch: Bool = false
    /// Hover / pressed state of the nearest ancestor marked `group`.
    @Entry var shellGroup: ShellGroupState = .init()
    /// Inherited text attributes (`fontSize`, `fontWeight`, …).
    @Entry var shellFont: ShellFontSpec = .init()
    /// A branch draws its own toolbar and command bar: native panes show
    /// only the page (see `PaneView`).
    @Entry var shellOwnsToolbar: Bool = false
}

struct ShellGroupState: Equatable {
    var hover = false
    var pressed = false
}

struct ShellFontSpec: Equatable {
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var italic = false

    var font: Font {
        let f = Font.system(size: size, weight: weight, design: design)
        return italic ? f.italic() : f
    }

    /// This spec with a node's own text attributes applied on top.
    func merging(_ style: ShellStyle) -> ShellFontSpec {
        var out = self
        if let s = style.fontSize { out.size = s }
        if let w = style.fontWeight { out.weight = Self.weight(w) }
        if let d = style.fontDesign { out.design = Self.design(d) }
        if let i = style.italic { out.italic = i }
        return out
    }

    static func weight(_ name: String) -> Font.Weight {
        switch name {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    static func design(_ name: String) -> Font.Design {
        switch name {
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        case "serif": return .serif
        default: return .default
        }
    }
}

enum ShellAlign {
    /// "topLeading" etc. → Alignment.
    static func alignment(_ name: String?) -> Alignment? {
        switch name {
        case "center": return .center
        case "top": return .top
        case "bottom": return .bottom
        case "leading", "start": return .leading
        case "trailing", "end": return .trailing
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return nil
        }
    }

    static func unitPoint(_ name: String?) -> UnitPoint {
        switch name {
        case "top": return .top
        case "bottom": return .bottom
        case "leading", "start": return .leading
        case "trailing", "end": return .trailing
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }

    static func unitPoint(_ alignment: Alignment) -> UnitPoint {
        let x: CGFloat = alignment.horizontal == .leading ? 0 : (alignment.horizontal == .trailing ? 1 : 0.5)
        let y: CGFloat = alignment.vertical == .top ? 0 : (alignment.vertical == .bottom ? 1 : 0.5)
        return UnitPoint(x: x, y: y)
    }

    /// Cross-axis alignment of a Row's children.
    static func vertical(_ name: String?) -> VerticalAlignment {
        switch name {
        case "start", "top": return .top
        case "end", "bottom": return .bottom
        case "baseline": return .firstTextBaseline
        default: return .center
        }
    }

    /// Cross-axis alignment of a Column's children.
    static func horizontal(_ name: String?) -> HorizontalAlignment {
        switch name {
        case "start", "leading": return .leading
        case "end", "trailing": return .trailing
        default: return .center
        }
    }

    /// Where a box's content sits inside the box when the box is bigger than
    /// its content: `justify` along the main axis, `align` across it.
    static func contentAnchor(type: String, style: ShellStyle) -> UnitPoint {
        func main(_ justify: String?) -> CGFloat {
            switch justify {
            case "center": return 0.5
            case "end": return 1
            default: return 0
            }
        }
        func cross(_ align: String?) -> CGFloat {
            switch align {
            case "start", "top", "leading": return 0
            case "end", "bottom", "trailing": return 1
            default: return 0.5
            }
        }
        switch type {
        case "row": return UnitPoint(x: main(style.justify), y: cross(style.align))
        case "column": return UnitPoint(x: cross(style.align), y: main(style.justify))
        default: return .center
        }
    }
}

/// Sizes a single child the way a CSS box would be sized.
struct ShellSizeLayout: Layout {
    var width: CGFloat?
    var height: CGFloat?
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
    var minHeight: CGFloat?
    var maxHeight: CGFloat?
    var fillWidth = false
    var fillHeight = false
    /// Where the child sits when the box ends up bigger than it.
    var anchor: UnitPoint = .center

    var isIdentity: Bool {
        width == nil && height == nil && minWidth == nil && maxWidth == nil && minHeight == nil && maxHeight == nil && !fillWidth && !fillHeight
    }

    private func childProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: ShellSizing.childProposal(proposal.width, fixed: width, lo: minWidth, hi: maxWidth, fill: fillWidth),
            height: ShellSizing.childProposal(proposal.height, fixed: height, lo: minHeight, hi: maxHeight, fill: fillHeight)
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(childProposal(proposal))
        return CGSize(
            width: ShellSizing.boxSize(proposal.width, child: size.width, fixed: width, lo: minWidth, hi: maxWidth, fill: fillWidth),
            height: ShellSizing.boxSize(proposal.height, child: size.height, fixed: height, lo: minHeight, hi: maxHeight, fill: fillHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let offered = ProposedViewSize(width: bounds.width, height: bounds.height)
        let size = child.sizeThatFits(offered)
        let x = bounds.minX + (bounds.width - size.width) * anchor.x
        let y = bounds.minY + (bounds.height - size.height) * anchor.y
        child.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: offered)
    }
}

/// Per-child placement inside a `ShellStackLayout`.
struct ShellAlignSelfKey: LayoutValueKey {
    static let defaultValue: Alignment? = nil
}

/// Layers children back to front. As big as its biggest child; each child is
/// offered the whole stack and placed by its `alignSelf` (default: the
/// stack's `align`).
struct ShellStackLayout: Layout {
    var alignment: Alignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            width = max(width, size.width)
            height = max(height, size.height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offered = ProposedViewSize(width: bounds.width, height: bounds.height)
        for subview in subviews {
            let anchor = ShellAlign.unitPoint(subview[ShellAlignSelfKey.self] ?? alignment)
            let size = subview.sizeThatFits(offered)
            let x = bounds.minX + (bounds.width - size.width) * anchor.x
            let y = bounds.minY + (bounds.height - size.height) * anchor.y
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: offered)
        }
    }
}

extension ShellStyle {
    /// The sizing box for this style given where the node sits.
    func sizeLayout(axis: ShellAxis, stretch: Bool, anchor: UnitPoint) -> ShellSizeLayout {
        var layout = ShellSizeLayout()
        layout.width = width?.points
        layout.height = height?.points
        layout.minWidth = minWidth
        layout.minHeight = minHeight
        layout.maxWidth = maxWidth?.points
        layout.maxHeight = maxHeight?.points
        layout.anchor = anchor

        var fillW = width?.isFill ?? false
        var fillH = height?.isFill ?? false
        if flex != nil {
            switch axis {
            case .row: fillW = true
            case .column: fillH = true
            case .stack:
                fillW = true
                fillH = true
            }
        }
        if stretch {
            switch axis {
            case .row: fillH = true
            case .column: fillW = true
            case .stack: break
            }
        }
        layout.fillWidth = fillW && layout.width == nil
        layout.fillHeight = fillH && layout.height == nil
        return layout
    }
}
