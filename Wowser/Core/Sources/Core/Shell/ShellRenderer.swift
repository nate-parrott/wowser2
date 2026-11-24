import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// Draws a `ShellNode` tree with SwiftUI.
//
// Each node type maps to a small view; `ShellStyled` applies the shared
// `style` (size, background, border, transforms, state variants, animation)
// and the interaction props (press, hover, drag & drop, menus). State looks
// such as `hover` and `pressed` are resolved here, natively — JS only hears
// about a hover if it asked with `onHover`.

/// Renders one node and, through it, its subtree.
struct ShellNodeView: View {
    let node: ShellNode

    var body: some View {
        switch node.type {
        case "row", "column", "stack", "root":
            ShellBoxView(node: node)
        case "text":
            ShellTextView(node: node)
        case "icon":
            ShellIconView(node: node)
        case "image":
            ShellImageView(node: node)
        case "favicon":
            ShellFaviconView(node: node)
        case "tabicon":
            ShellTabIconView(node: node)
        case "spacer":
            ShellSpacerView(node: node)
        case "divider":
            Divider().shellStyled(node)
        case "scroll":
            ShellScrollView(node: node)
        case "textinput":
            ShellTextInputView(node: node)
        case "menu":
            ShellMenuButton(node: node)
        case "popover":
            ShellPopoverView(node: node)
        case "webpane":
            ShellWebPaneView(node: node)
        case "webisland":
            ShellWebIslandView(node: node)
        case "windowcontrols":
            ShellWindowControlsView(node: node)
        case "native":
            ShellNativeView(node: node)
        default:
            EmptyView()
        }
    }
}

/// The children of a node, each in its own identity-stable view.
struct ShellChildren: View {
    let node: ShellNode

    var body: some View {
        ForEach(node.children) { child in
            ShellNodeView(node: child)
        }
    }
}

// MARK: - Boxes

struct ShellBoxView: View {
    let node: ShellNode
    @Environment(\.shellFont) private var inheritedFont

    var body: some View {
        // Structure follows the base style; state variants only restyle.
        let style = node.style()
        let stretch = style.align == "stretch"
        Group {
            switch node.type {
            case "row":
                HStack(alignment: ShellAlign.vertical(style.align), spacing: style.gap ?? 0) {
                    distributed(style.justify)
                }
                .environment(\.shellAxis, .row)
            case "column":
                VStack(alignment: ShellAlign.horizontal(style.align), spacing: style.gap ?? 0) {
                    distributed(style.justify)
                }
                .environment(\.shellAxis, .column)
            default:
                ShellStackLayout(alignment: ShellAlign.alignment(style.align) ?? .center) {
                    ShellChildren(node: node)
                }
                .environment(\.shellAxis, .stack)
            }
        }
        .environment(\.shellStretch, stretch)
        .environment(\.shellFont, inheritedFont.merging(style))
        .animation(ShellMotion.animation(style.animate), value: node.children.map(\.id))
        .shellStyled(node)
    }

    /// `justify: between | around | evenly` spreads children with spacers;
    /// start / center / end are handled by where the box anchors its content.
    @ViewBuilder
    private func distributed(_ justify: String?) -> some View {
        switch justify {
        case "between":
            ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                if index > 0 { Spacer(minLength: 0) }
                ShellNodeView(node: child)
            }
        case "around", "evenly":
            Spacer(minLength: 0)
            ForEach(node.children) { child in
                ShellNodeView(node: child)
                Spacer(minLength: 0)
            }
        default:
            ShellChildren(node: node)
        }
    }
}

struct ShellSpacerView: View {
    let node: ShellNode

    var body: some View {
        let style = node.style()
        Spacer(minLength: max(style.minWidth ?? 0, style.minHeight ?? 0))
    }
}

// MARK: - Colours

struct ShellPalette {
    var onAccent: Color

    func color(_ token: String?) -> Color? {
        guard let token else { return nil }
        let parsed = ShellColorToken(token)
        let base: Color
        switch parsed.base {
        case .rgba(let r, let g, let b, let a):
            base = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        case .named(let name):
            switch name {
            case "primary": base = .primary
            case "secondary": base = .secondary
            case "tertiary": base = Color.primary.opacity(0.26)
            case "accent": base = .accentColor
            case "onAccent": base = onAccent
            case "background": base = Color("Background", bundle: .module)
            case "tabBackground": base = Color("TabBackground", bundle: .module)
            case "separator": base = Color.primary.opacity(0.1)
            case "clear": base = .clear
            case "white": base = .white
            case "black": base = .black
            case "red": base = .red
            case "orange": base = .orange
            case "yellow": base = .yellow
            case "green": base = .green
            case "blue": base = .blue
            case "purple": base = .purple
            case "pink": base = .pink
            case "gray": base = .gray
            default: base = .clear
            }
        }
        return parsed.alpha >= 1 ? base : base.opacity(parsed.alpha)
    }
}

enum ShellMotion {
    static func animation(_ spec: ShellAnimationSpec?) -> Animation? {
        guard let spec else { return nil }
        switch spec {
        case .standard: return .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
        case .snappy: return .snappy
        case .smooth: return .smooth
        case .bouncy: return .bouncy
        case .spring(let duration, let bounce): return .spring(duration: duration, bounce: bounce)
        case .ease(let kind, let duration):
            switch kind {
            case "easeIn": return .easeIn(duration: duration)
            case "easeOut": return .easeOut(duration: duration)
            case "linear": return .linear(duration: duration)
            default: return .timingCurve(0.25, 0.1, 0.25, 1, duration: duration)
            }
        }
    }

    static func transition(_ json: ShellJSON?) -> AnyTransition {
        guard let json else { return .identity }
        if let name = json.string {
            switch name {
            case "opacity": return .opacity
            case "scale": return .scale(scale: 0.9).combined(with: .opacity)
            case "slide": return .slide
            default: return .identity
            }
        }
        switch json["type"]?.string {
        case "move":
            let edge: Edge
            switch json["edge"]?.string {
            case "top": edge = .top
            case "leading": edge = .leading
            case "trailing": edge = .trailing
            default: edge = .bottom
            }
            return .move(edge: edge).combined(with: .opacity)
        case "scale":
            return .scale(scale: json["scale"]?.double ?? 0.9, anchor: ShellAlign.unitPoint(json["anchor"]?.string)).combined(with: .opacity)
        case "offset":
            return .offset(x: json["x"]?.double ?? 0, y: json["y"]?.double ?? 0).combined(with: .opacity)
        default:
            return .identity
        }
    }
}

// MARK: - Shared style + interaction

/// Reports that a text input inside this subtree holds keyboard focus.
struct ShellFocusWithinKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Wrap this node content in its `style` and interaction props.
    func shellStyled(_ node: ShellNode) -> some View {
        ShellStyledView(node: node, content: self)
    }
}

/// Applies a node's `style` and interaction props around its content.
struct ShellStyledView<Content: View>: View {
    let node: ShellNode
    let content: Content

    @Environment(ShellEngine.self) private var engine
    @Environment(\.shellAxis) private var axis
    @Environment(\.shellStretch) private var stretch
    @Environment(\.shellGroup) private var group
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onAccentColor) private var onAccentColor

    @State private var hovered = false
    @State private var dropTargeted = false
    @State private var focusWithin = false
    @State private var gesturePressed = false
    @State private var lastTap = Date.distantPast
    @State private var panning = false

    var body: some View {
        let declared = node.declaredStates
        let pressable = node.handles("onPress") || node.handles("onDoublePress")
        // A Button gives a native pressed state and plays well with scrolling,
        // but swallows drags; draggable and double-click nodes use gestures.
        let useButton = node.handles("onPress") && !node.handles("onDoublePress") && node.props["draggable"] == nil

        Group {
            if useButton {
                Button(action: { press(at: nil) }) { EmptyView() }
                    .buttonStyle(ShellPressStyle { pressed in
                        visuals(pressed: pressed, declared: declared)
                    })
                    .disabled(node.bool("disabled"))
            } else if pressable {
                visuals(pressed: gesturePressed, declared: declared)
                    .onTapGesture { location in tapped(at: location) }
                    .onLongPressGesture(minimumDuration: 60, maximumDistance: 30, perform: {}, onPressingChanged: { pressing in
                        if declared.contains(.pressed) || node.bool("group") { gesturePressed = pressing }
                    })
            } else {
                visuals(pressed: false, declared: declared)
            }
        }
        .modifier(ShellInteractions(node: node, hovered: $hovered, dropTargeted: $dropTargeted, panning: $panning, trackHover: declared.contains(.hover) || node.bool("group") || node.handles("onHover")))
        .modifier(ShellPlacement(node: node, style: node.style()))
    }

    // MARK: Visuals

    private func state(pressed: Bool, declared: ShellStyleState) -> ShellStyleState {
        guard !declared.isEmpty else { return [] }
        var s: ShellStyleState = []
        if colorScheme == .dark { s.insert(.dark) }
        if group.hover { s.insert(.groupHover) }
        if group.pressed { s.insert(.groupPressed) }
        if hovered { s.insert(.hover) }
        if focusWithin { s.insert(.focused) }
        if pressed || panning { s.insert(.pressed) }
        if dropTargeted { s.insert(.dropTarget) }
        if node.bool("disabled") { s.insert(.disabled) }
        // Disabled nodes don't react to the pointer.
        if s.contains(.disabled) { s.subtract([.hover, .pressed]) }
        return s.intersection(declared)
    }

    @ViewBuilder
    private func visuals(pressed: Bool, declared: ShellStyleState) -> some View {
        let style = node.style(state(pressed: pressed, declared: declared))
        let palette = ShellPalette(onAccent: onAccentColor)
        let shape = ShellShape.shape(style)
        let anchor = ShellAlign.unitPoint(style.anchor)
        let isBox = node.type == "row" || node.type == "column" || node.type == "stack" || node.type == "root"
        let interactive = node.handles("onPress") || node.handles("onDoublePress") || node.handles("onHover") || node.handles("onPan")
            || node.props["dropTypes"] != nil || node.props["contextMenu"] != nil || node.bool("windowDrag") || declared.contains(.hover)

        style.sizeLayout(axis: axis, stretch: stretch, anchor: isBox ? ShellAlign.contentAnchor(type: node.type, style: style) : .center) {
            content
                .foregroundStyle(palette.color(style.color) ?? .primary, when: style.color != nil)
                .padding(style.padding)
        }
        .modifier(ShellBackgroundModifier(background: style.background, shadow: style.shadow, shape: shape, palette: palette))
        .overlay {
            if let border = style.border, let color = palette.color(border.color) {
                shape.strokeBorder(color, lineWidth: border.width).allowsHitTesting(false)
            }
        }
        .modifier(ShellClip(shape: shape, clip: style.clip))
        .contentShape(shape, when: interactive)
        .opacity(style.hidden ? 0 : (style.opacity ?? 1))
        .allowsHitTesting(!style.hidden)
        .blur(radius: style.blur ?? 0)
        .scaleEffect(x: (style.scale ?? 1) * (style.scaleX ?? 1), y: (style.scale ?? 1) * (style.scaleY ?? 1), anchor: anchor)
        .rotationEffect(.degrees(style.rotate ?? 0), anchor: anchor)
        .offset(x: style.offset?.width ?? 0, y: style.offset?.height ?? 0)
        .padding(style.margin)
        .environment(\.shellGroup, node.bool("group") ? ShellGroupState(hover: hovered, pressed: pressed) : group)
        .onPreferenceChange(ShellFocusWithinKey.self) { value in
            if declared.contains(.focused), focusWithin != value { focusWithin = value }
        }
        .animation(ShellMotion.animation(style.animate), value: style)
    }

    // MARK: Press handling

    private func modifiers() -> ShellJSON {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return ["cmd": .bool(flags.contains(.command)), "shift": .bool(flags.contains(.shift)), "alt": .bool(flags.contains(.option)), "ctrl": .bool(flags.contains(.control))]
        #else
        return ["cmd": false, "shift": false, "alt": false, "ctrl": false]
        #endif
    }

    private func pressPayload(at point: CGPoint?) -> ShellJSON {
        let p = point ?? CGPoint(x: (node.frame?.width ?? 0) / 2, y: (node.frame?.height ?? 0) / 2)
        return ["modifiers": modifiers(), "x": .number(Double(p.x)), "y": .number(Double(p.y))]
    }

    private func press(at point: CGPoint?) {
        guard !node.bool("disabled") else { return }
        engine.dispatch(node.id, "onPress", pressPayload(at: point))
    }

    /// Single taps fire immediately; a second tap within the double-click
    /// interval also fires `onDoublePress` (so single-click stays instant).
    private func tapped(at point: CGPoint) {
        guard !node.bool("disabled") else { return }
        let now = Date()
        let isDouble = node.handles("onDoublePress") && now.timeIntervalSince(lastTap) < 0.35
        lastTap = isDouble ? .distantPast : now
        if isDouble {
            engine.dispatch(node.id, "onDoublePress", pressPayload(at: point))
        } else if node.handles("onPress") {
            engine.dispatch(node.id, "onPress", pressPayload(at: point))
        }
    }
}

/// A button style that hands its pressed state to a builder and ignores the
/// label: the node's own visuals are the button.
struct ShellPressStyle<V: View>: ButtonStyle {
    let build: (Bool) -> V

    func makeBody(configuration: Configuration) -> some View {
        build(configuration.isPressed)
    }
}

enum ShellShape {
    static func shape(_ style: ShellStyle) -> UnevenRoundedRectangle {
        let c = style.cornerRadius
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: c?.topLeading ?? 0,
                bottomLeading: c?.bottomLeading ?? 0,
                bottomTrailing: c?.bottomTrailing ?? 0,
                topTrailing: c?.topTrailing ?? 0
            ),
            style: style.cornerCircular ? .circular : .continuous
        )
    }
}

private struct ShellClip: ViewModifier {
    var shape: UnevenRoundedRectangle
    var clip: Bool

    func body(content: Content) -> some View {
        if clip { content.clipShape(shape) } else { content }
    }
}

private struct ShellBackgroundModifier: ViewModifier {
    var background: ShellBackground?
    var shadow: ShellShadow?
    var shape: UnevenRoundedRectangle
    var palette: ShellPalette

    private var shadowColor: Color {
        palette.color(shadow?.color) ?? Color.black.opacity(0.33)
    }

    func body(content: Content) -> some View {
        switch background {
        case .none:
            if let shadow {
                content.shadow(color: shadowColor, radius: shadow.radius, x: shadow.x, y: shadow.y)
            } else {
                content
            }
        case .color(let token):
            // The shadow belongs to the box, not to the text inside it.
            content.background {
                shape.fill(palette.color(token) ?? .clear)
                    .shadow(color: shadow == nil ? .clear : shadowColor, radius: shadow?.radius ?? 0, x: shadow?.x ?? 0, y: shadow?.y ?? 0)
            }
        case .gradient(let colors, let from, let to):
            content.background {
                shape.fill(LinearGradient(
                    colors: colors.compactMap { palette.color($0) },
                    startPoint: ShellAlign.unitPoint(from ?? "topLeading"),
                    endPoint: ShellAlign.unitPoint(to ?? "bottomTrailing")
                ))
                .shadow(color: shadow == nil ? .clear : shadowColor, radius: shadow?.radius ?? 0, x: shadow?.x ?? 0, y: shadow?.y ?? 0)
            }
        case .material(let name, let tint, let interactive):
            material(content, name: name, tint: palette.color(tint), interactive: interactive)
                .shadow(color: shadow == nil ? .clear : shadowColor, radius: shadow?.radius ?? 0, x: shadow?.x ?? 0, y: shadow?.y ?? 0)
        }
    }

    @ViewBuilder
    private func material(_ content: Content, name: String, tint: Color?, interactive: Bool) -> some View {
        switch name {
        case "glass":
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        case "sidebar":
            content.background { TransparentBg().clipShape(shape) }
        default:
            content.background {
                ZStack {
                    shape.fill(Self.systemMaterial(name))
                    if let tint { shape.fill(tint) }
                }
            }
        }
    }

    private static func systemMaterial(_ name: String) -> Material {
        switch name {
        case "ultraThin": return .ultraThinMaterial
        case "thin": return .thinMaterial
        case "thick": return .thickMaterial
        case "ultraThick": return .ultraThickMaterial
        case "bar": return .bar
        default: return .regularMaterial
        }
    }
}

/// Outside-the-box concerns: where the node sits in its parent, and frame tracking.
private struct ShellPlacement: ViewModifier {
    let node: ShellNode
    let style: ShellStyle
    @Environment(ShellEngine.self) private var engine

    func body(content: Content) -> some View {
        content
            .zIndex(style.zIndex ?? 0)
            .layoutPriority(style.layoutPriority ?? 0)
            .layoutValue(key: ShellAlignSelfKey.self, value: ShellAlign.alignment(style.alignSelf))
            .transition(ShellMotion.transition(style.transition))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(ShellCoordinateSpace.root))
            } action: { frame in
                node.frame = frame
                if node.handles("onLayout") {
                    engine.dispatch(node.id, "onLayout", [
                        "x": .number(Double(frame.minX)), "y": .number(Double(frame.minY)),
                        "width": .number(Double(frame.width)), "height": .number(Double(frame.height)),
                    ])
                }
            }
            .modifier(ShellAnchor(id: node.string("anchorId")))
    }
}

/// Makes a node a `ScrollView` `scrollTo` target.
private struct ShellAnchor: ViewModifier {
    var id: String?

    func body(content: Content) -> some View {
        if let id { content.id(id) } else { content }
    }
}

enum ShellCoordinateSpace {
    static let root = "ShellRoot"
}

extension View {
    @ViewBuilder
    fileprivate func foregroundStyle(_ color: Color, when condition: Bool) -> some View {
        if condition { self.foregroundStyle(color) } else { self }
    }

    @ViewBuilder
    fileprivate func contentShape(_ shape: UnevenRoundedRectangle, when condition: Bool) -> some View {
        if condition { self.contentShape(shape) } else { self }
    }

    @ViewBuilder
    func padding(_ edges: ShellEdges?) -> some View {
        if let edges, !edges.isZero {
            self.padding(EdgeInsets(top: edges.top, leading: edges.leading, bottom: edges.bottom, trailing: edges.trailing))
        } else {
            self
        }
    }
}
