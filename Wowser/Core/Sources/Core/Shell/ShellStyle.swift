import Foundation

/// Interaction states a style can react to (`hover: {…}`, `pressed: {…}`).
public struct ShellStyleState: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let hover = ShellStyleState(rawValue: 1 << 0)
    public static let pressed = ShellStyleState(rawValue: 1 << 1)
    public static let disabled = ShellStyleState(rawValue: 1 << 2)
    public static let focused = ShellStyleState(rawValue: 1 << 3)
    public static let dropTarget = ShellStyleState(rawValue: 1 << 4)
    public static let groupHover = ShellStyleState(rawValue: 1 << 5)
    public static let groupPressed = ShellStyleState(rawValue: 1 << 6)
    public static let dark = ShellStyleState(rawValue: 1 << 7)

    /// Variant keys in the order they are layered (later wins).
    static let keys: [(String, ShellStyleState)] = [
        ("dark", .dark),
        ("groupHover", .groupHover),
        ("groupPressed", .groupPressed),
        ("hover", .hover),
        ("focused", .focused),
        ("pressed", .pressed),
        ("dropTarget", .dropTarget),
        ("disabled", .disabled),
    ]
}

public enum ShellLength: Equatable, Sendable {
    case points(CGFloat)
    case fill

    init?(_ json: ShellJSON?) {
        guard let json else { return nil }
        if let n = json.double { self = .points(CGFloat(n)) }
        else if json.string == "fill" { self = .fill }
        else { return nil }
    }

    var points: CGFloat? {
        if case .points(let p) = self { return p }
        return nil
    }
    var isFill: Bool { self == .fill }
}

public struct ShellEdges: Equatable, Sendable {
    public var top: CGFloat = 0
    public var leading: CGFloat = 0
    public var bottom: CGFloat = 0
    public var trailing: CGFloat = 0

    public var isZero: Bool { top == 0 && leading == 0 && bottom == 0 && trailing == 0 }

    init?(_ json: ShellJSON?) {
        guard let json else { return nil }
        switch json {
        case .number(let n):
            let v = CGFloat(n)
            top = v; leading = v; bottom = v; trailing = v
        case .array(let a):
            guard a.count == 2, let v = a[0].double, let h = a[1].double else { return nil }
            top = CGFloat(v); bottom = CGFloat(v); leading = CGFloat(h); trailing = CGFloat(h)
        case .object(let o):
            let h = o["horizontal"]?.double ?? 0
            let v = o["vertical"]?.double ?? 0
            top = CGFloat(o["top"]?.double ?? v)
            bottom = CGFloat(o["bottom"]?.double ?? v)
            leading = CGFloat(o["left"]?.double ?? o["leading"]?.double ?? h)
            trailing = CGFloat(o["right"]?.double ?? o["trailing"]?.double ?? h)
        default:
            return nil
        }
    }
}

public struct ShellCorners: Equatable, Sendable {
    public var topLeading: CGFloat = 0
    public var topTrailing: CGFloat = 0
    public var bottomLeading: CGFloat = 0
    public var bottomTrailing: CGFloat = 0

    public var uniform: CGFloat? {
        (topLeading == topTrailing && topLeading == bottomLeading && topLeading == bottomTrailing) ? topLeading : nil
    }
    public var isZero: Bool { uniform == 0 }

    init?(_ json: ShellJSON?) {
        guard let json else { return nil }
        if let n = json.double {
            let v = CGFloat(n)
            topLeading = v; topTrailing = v; bottomLeading = v; bottomTrailing = v
        } else if let o = json.object {
            topLeading = CGFloat(o["topLeft"]?.double ?? 0)
            topTrailing = CGFloat(o["topRight"]?.double ?? 0)
            bottomLeading = CGFloat(o["bottomLeft"]?.double ?? 0)
            bottomTrailing = CGFloat(o["bottomRight"]?.double ?? 0)
        } else {
            return nil
        }
    }
}

public enum ShellBackground: Equatable, Sendable {
    case color(String)
    case gradient(colors: [String], from: String?, to: String?)
    case material(name: String, tint: String?, interactive: Bool)

    init?(_ json: ShellJSON?) {
        guard let json else { return nil }
        if let s = json.string {
            self = .color(s)
        } else if let o = json.object {
            if let colors = o["gradient"]?.array {
                self = .gradient(colors: colors.compactMap(\.string), from: o["from"]?.string, to: o["to"]?.string)
            } else if let name = o["material"]?.string {
                self = .material(name: name, tint: o["tint"]?.string, interactive: o["interactive"]?.bool ?? false)
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}

public struct ShellShadow: Equatable, Sendable {
    public var color: String?
    public var radius: CGFloat
    public var x: CGFloat
    public var y: CGFloat

    init?(_ json: ShellJSON?) {
        guard let o = json?.object, let r = o["radius"]?.double else { return nil }
        color = o["color"]?.string
        radius = CGFloat(r)
        x = CGFloat(o["x"]?.double ?? 0)
        y = CGFloat(o["y"]?.double ?? 0)
    }
}

public struct ShellBorder: Equatable, Sendable {
    public var color: String
    public var width: CGFloat

    init?(_ json: ShellJSON?) {
        guard let o = json?.object, let c = o["color"]?.string else { return nil }
        color = c
        width = CGFloat(o["width"]?.double ?? 1)
    }
}

/// `style.animate`, parsed.
public enum ShellAnimationSpec: Equatable, Sendable {
    case standard
    case snappy
    case smooth
    case bouncy
    case spring(duration: Double, bounce: Double)
    case ease(kind: String, duration: Double)

    init?(_ json: ShellJSON?) {
        guard let json else { return nil }
        switch json {
        case .bool(let on):
            if on { self = .standard } else { return nil }
        case .string(let s):
            switch s {
            case "snappy": self = .snappy
            case "smooth": self = .smooth
            case "bouncy": self = .bouncy
            default: self = .standard
            }
        case .object(let o):
            let type = o["type"]?.string ?? "ease"
            if type == "spring" {
                self = .spring(duration: o["duration"]?.double ?? 0.35, bounce: o["bounce"]?.double ?? 0)
            } else {
                self = .ease(kind: type, duration: o["duration"]?.double ?? 0.2)
            }
        default:
            return nil
        }
    }
}

/// A node's style for one interaction state, parsed into typed fields.
/// Colours stay as tokens; the renderer resolves them against the theme.
public struct ShellStyle: Equatable, Sendable {
    // size
    public var width: ShellLength?
    public var height: ShellLength?
    public var minWidth: CGFloat?
    public var maxWidth: ShellLength?
    public var minHeight: CGFloat?
    public var maxHeight: ShellLength?
    public var flex: Double?
    public var layoutPriority: Double?
    public var aspectRatio: CGFloat?
    // spacing
    public var padding: ShellEdges?
    public var margin: ShellEdges?
    // placement
    public var alignSelf: String?
    public var offset: CGSize?
    public var zIndex: Double?
    // appearance
    public var background: ShellBackground?
    public var color: String?
    public var opacity: Double?
    public var cornerRadius: ShellCorners?
    public var cornerCircular = false
    public var border: ShellBorder?
    public var shadow: ShellShadow?
    public var clip = false
    public var blur: CGFloat?
    public var scale: CGFloat?
    public var scaleX: CGFloat?
    public var scaleY: CGFloat?
    public var rotate: Double?
    public var anchor: String?
    public var hidden = false
    public var cursor: String?
    // motion
    public var animate: ShellAnimationSpec?
    public var transition: ShellJSON?
    // text (inherited)
    public var fontSize: CGFloat?
    public var fontWeight: String?
    public var fontDesign: String?
    public var italic: Bool?
    // box
    public var gap: CGFloat?
    public var align: String?
    public var justify: String?
    // text
    public var lineLimit: Int?
    public var truncate: String?
    public var textAlign: String?
    public var letterSpacing: CGFloat?
    public var lineSpacing: CGFloat?
    public var underline = false
    public var strikethrough = false
    public var monospacedDigits = false
    public var selectable = false
    public var placeholderColor: String?

    public init() {}

    /// Layer the variants selected by `state` over the base keys of `raw`.
    public init(raw: [String: ShellJSON], state: ShellStyleState) {
        var merged = raw
        if !state.isEmpty {
            for (key, flag) in ShellStyleState.keys where state.contains(flag) {
                if let variant = raw[key]?.object {
                    for (k, v) in variant { merged[k] = v }
                }
            }
        }
        func num(_ key: String) -> CGFloat? { merged[key]?.double.map { CGFloat($0) } }
        func flag(_ key: String) -> Bool { merged[key]?.bool ?? false }

        width = ShellLength(merged["width"])
        height = ShellLength(merged["height"])
        minWidth = num("minWidth")
        maxWidth = ShellLength(merged["maxWidth"])
        minHeight = num("minHeight")
        maxHeight = ShellLength(merged["maxHeight"])
        flex = merged["flex"]?.double
        layoutPriority = merged["layoutPriority"]?.double
        aspectRatio = num("aspectRatio")
        padding = ShellEdges(merged["padding"])
        margin = ShellEdges(merged["margin"])
        alignSelf = merged["alignSelf"]?.string
        if let o = merged["offset"]?.object {
            offset = CGSize(width: o["x"]?.double ?? 0, height: o["y"]?.double ?? 0)
        }
        zIndex = merged["zIndex"]?.double
        background = ShellBackground(merged["background"])
        color = merged["color"]?.string
        opacity = merged["opacity"]?.double
        cornerRadius = ShellCorners(merged["cornerRadius"])
        cornerCircular = merged["cornerStyle"]?.string == "circular"
        border = ShellBorder(merged["border"])
        shadow = ShellShadow(merged["shadow"])
        clip = flag("clip")
        blur = num("blur")
        scale = num("scale")
        scaleX = num("scaleX")
        scaleY = num("scaleY")
        rotate = merged["rotate"]?.double
        anchor = merged["anchor"]?.string
        hidden = flag("hidden")
        cursor = merged["cursor"]?.string
        animate = ShellAnimationSpec(merged["animate"])
        transition = merged["transition"]
        fontSize = num("fontSize")
        fontWeight = merged["fontWeight"]?.string
        fontDesign = merged["fontDesign"]?.string
        italic = merged["italic"]?.bool
        gap = num("gap")
        align = merged["align"]?.string
        justify = merged["justify"]?.string
        lineLimit = merged["lineLimit"]?.int
        truncate = merged["truncate"]?.string
        textAlign = merged["textAlign"]?.string
        letterSpacing = num("letterSpacing")
        lineSpacing = num("lineSpacing")
        underline = flag("underline")
        strikethrough = flag("strikethrough")
        monospacedDigits = flag("monospacedDigits")
        selectable = flag("selectable")
        placeholderColor = merged["placeholderColor"]?.string
    }
}

/// A colour token (`"accent/0.5"`, `"#1e2228"`, `"primary"`) split into its
/// base and alpha multiplier. Resolution to a real colour is the renderer's job.
public struct ShellColorToken: Equatable, Sendable {
    public enum Base: Equatable, Sendable {
        case named(String)
        /// 0…1 components.
        case rgba(Double, Double, Double, Double)
    }
    public var base: Base
    public var alpha: Double

    public init(_ token: String) {
        var name = Substring(token)
        var alpha = 1.0
        if let slash = token.lastIndex(of: "/"), slash != token.startIndex,
           let a = Double(token[token.index(after: slash)...]) {
            alpha = a
            name = token[..<slash]
        }
        self.alpha = alpha
        if name.hasPrefix("#"), let rgba = ShellColorToken.parseHex(String(name.dropFirst())) {
            base = .rgba(rgba.0, rgba.1, rgba.2, rgba.3)
        } else {
            base = .named(String(name))
        }
    }

    static func parseHex(_ hex: String) -> (Double, Double, Double, Double)? {
        var h = hex
        if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let value = UInt64(h, radix: 16) else { return nil }
        if h.count == 6 {
            return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255, 1)
        }
        return (Double((value >> 24) & 0xff) / 255, Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// "#rrggbb" or "#rrggbbaa" for 0…1 components.
    static func hex(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> String {
        func c(_ v: Double) -> String {
            let n = Int((min(max(v, 0), 1) * 255).rounded())
            return (n < 16 ? "0" : "") + String(n, radix: 16)
        }
        return "#" + c(r) + c(g) + c(b) + (a < 0.999 ? c(a) : "")
    }
}

/// The arithmetic behind `ShellSizeLayout`, one axis at a time. Kept free of
/// SwiftUI so it can be tested anywhere.
///
/// A box is *fixed* (`width: 30`), *filling* (`flex`, `width: "fill"`, or a
/// stretching parent) or *hugging* (neither). `lo` / `hi` are `minWidth` /
/// `maxWidth`.
public enum ShellSizing {
    static func clamp(_ value: CGFloat, _ lo: CGFloat?, _ hi: CGFloat?) -> CGFloat {
        var v = value
        if let hi { v = min(v, hi) }
        if let lo { v = max(v, lo) }
        return v
    }

    /// What the box offers its content, given what the box was offered
    /// (`nil` = "your ideal size").
    public static func childProposal(_ proposed: CGFloat?, fixed: CGFloat?, lo: CGFloat?, hi: CGFloat?, fill: Bool) -> CGFloat? {
        if let fixed { return fixed }
        guard let proposed else { return nil }
        // A cap limits what the content is offered; a filling box passes on
        // everything it was offered, within its limits.
        return fill ? clamp(proposed, lo, hi) : clamp(proposed, nil, hi)
    }

    /// The box's own size, given what it was offered and what its content took.
    public static func boxSize(_ proposed: CGFloat?, child: CGFloat, fixed: CGFloat?, lo: CGFloat?, hi: CGFloat?, fill: Bool) -> CGFloat {
        if let fixed { return fixed }
        if fill, let proposed { return clamp(proposed, lo, hi) }
        return clamp(child, lo, hi)
    }
}
