import Foundation

// MARK: - Customizable trailing toolbar region
//
// The buttons on the trailing edge of a web tab's toolbar are a user-ordered
// list of `ToolbarItemRef`s: built-in buttons (`ToolbarTrailingItem`) plus
// user-created `CustomToolbarButton`s. The config lives in BrowserState so
// BrowserJS (`browser.toolbar.*`) and the customizer popover edit the same
// value and every window's toolbar observes it.

/// A user-defined toolbar button. `bjs` is the body of an async BrowserJS
/// function run on click (with `browser` and `args` in scope). When `bjs` is
/// nil, clicking spawns a background agent with the current page + click
/// details instead — for buttons whose job needs judgment rather than code.
public struct CustomToolbarButton: Equatable, Codable, Identifiable {
    public var id: String
    public var label: String
    /// SF Symbol name.
    public var icon: String
    public var bjs: String?
    /// Free-text description of what the button should do (what the user
    /// typed when creating it). Given to the agent that authors / runs it.
    public var instructions: String?

    public init(id: String = UUID().uuidString.lowercased(), label: String, icon: String = CustomToolbarButton.randomIcon(), bjs: String? = nil, instructions: String? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
        self.bjs = bjs
        self.instructions = instructions
    }

    /// A meaningless placeholder glyph for a freshly created button, until
    /// the agent picks a real one.
    public static func randomIcon() -> String {
        ["circle.dashed", "seal", "hexagon", "diamond", "pentagon", "octagon", "star", "triangle", "rhombus", "shield", "capsule", "oval"].randomElement()!
    }
}

public enum ToolbarItemRef: Hashable, Codable {
    case builtin(ToolbarTrailingItem)
    case custom(String)

    /// Stable string form, used by the customizer's drag & drop.
    public var key: String {
        switch self {
        case .builtin(let item): return "builtin:" + item.rawValue
        case .custom(let id): return "custom:" + id
        }
    }

    public init?(key: String) {
        if key.hasPrefix("builtin:"), let item = ToolbarTrailingItem(rawValue: String(key.dropFirst(8))) {
            self = .builtin(item)
        } else if key.hasPrefix("custom:") {
            self = .custom(String(key.dropFirst(7)))
        } else {
            return nil
        }
    }
}

public struct ToolbarConfig: Equatable, Codable {
    /// Every item (built-in and custom) in display order. Items missing from
    /// here are appended in default order by `resolvedOrder`, so new
    /// built-ins / custom buttons never need a migration.
    public var order: [ToolbarItemRef] = []
    /// Items switched off in the customizer. They keep their place in
    /// `order` (so toggling never reorders the list) but don't render.
    public var hidden: Set<ToolbarItemRef> = ToolbarConfig.defaultHidden
    public var customButtons: [CustomToolbarButton] = []

    /// Off until switched on in the customizer. Default bar: mobile viewport
    /// (dev mode only), open chat, close pane.
    public static let defaultHidden: Set<ToolbarItemRef> = [.builtin(.dictation), .builtin(.cleanMode), .builtin(.bookmark), .builtin(.newSplitPane)]

    public init() {}

    enum CodingKeys: String, CodingKey { case order, hidden, customButtons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([ToolbarItemRef].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent(Set<ToolbarItemRef>.self, forKey: .hidden) ?? Self.defaultHidden
        customButtons = try c.decodeIfPresent([CustomToolbarButton].self, forKey: .customButtons) ?? []
    }

    /// All items in display order (custom buttons that no longer exist are
    /// dropped; unknown built-ins / custom buttons are appended).
    public var resolvedOrder: [ToolbarItemRef] {
        let known = Set(order)
        let customIDs = Set(customButtons.map(\.id))
        var out = order.filter {
            if case .custom(let id) = $0 { return customIDs.contains(id) }
            return true
        }
        out += ToolbarTrailingItem.allCases.map(ToolbarItemRef.builtin).filter { !known.contains($0) }
        out += customButtons.map { ToolbarItemRef.custom($0.id) }.filter { !known.contains($0) }
        return out
    }

    /// The items that render in the bar, in order.
    public var barItems: [ToolbarItemRef] {
        resolvedOrder.filter { !hidden.contains($0) }
    }

    public func customButton(id: String) -> CustomToolbarButton? {
        customButtons.first(where: { $0.id == id })
    }
}

public extension BrowserState {
    var toolbarConfig: ToolbarConfig {
        get { toolbar ?? ToolbarConfig() }
        set { toolbar = newValue }
    }

    /// New buttons go straight into the bar (at the end).
    mutating func addCustomToolbarButton(_ button: CustomToolbarButton) {
        var cfg = toolbarConfig
        guard cfg.customButton(id: button.id) == nil else { return }
        cfg.customButtons.append(button)
        cfg.order = cfg.resolvedOrder + [.custom(button.id)]
        toolbarConfig = cfg
    }

    mutating func updateCustomToolbarButton(id: String, _ block: (inout CustomToolbarButton) -> Void) {
        var cfg = toolbarConfig
        guard let idx = cfg.customButtons.firstIndex(where: { $0.id == id }) else { return }
        block(&cfg.customButtons[idx])
        toolbarConfig = cfg
    }

    mutating func removeCustomToolbarButton(id: String) {
        var cfg = toolbarConfig
        cfg.customButtons.removeAll(where: { $0.id == id })
        cfg.order.removeAll(where: { $0 == .custom(id) })
        cfg.hidden.remove(.custom(id))
        toolbarConfig = cfg
    }

    mutating func setToolbarItemShown(_ ref: ToolbarItemRef, _ shown: Bool) {
        var cfg = toolbarConfig
        if shown { cfg.hidden.remove(ref) } else { cfg.hidden.insert(ref) }
        toolbarConfig = cfg
    }

    mutating func moveToolbarItems(fromOffsets: IndexSet, toOffset: Int) {
        var cfg = toolbarConfig
        var order = cfg.resolvedOrder
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        cfg.order = order
        toolbarConfig = cfg
    }

    /// Built-in buttons back in default order, all shown; custom buttons kept.
    mutating func resetToolbarToDefault() {
        var cfg = toolbarConfig
        cfg.order = ToolbarTrailingItem.allCases.map(ToolbarItemRef.builtin) + cfg.customButtons.map { .custom($0.id) }
        cfg.hidden = ToolbarConfig.defaultHidden
        toolbarConfig = cfg
    }
}
