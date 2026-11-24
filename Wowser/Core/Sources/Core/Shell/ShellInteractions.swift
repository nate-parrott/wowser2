import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Hover, drag & drop, context menu, pan, window dragging, cursor, tooltip
/// and accessibility for a node — everything interactive except the press
/// itself (see `ShellStyledView`).
struct ShellInteractions: ViewModifier {
    let node: ShellNode
    @Binding var hovered: Bool
    @Binding var dropTargeted: Bool
    @Binding var panning: Bool
    var trackHover: Bool

    @Environment(ShellEngine.self) private var engine

    func body(content: Content) -> some View {
        content
            .modifier(ShellHover(enabled: trackHover) { hovering in
                if hovered != hovering { hovered = hovering }
                if node.handles("onHover") { engine.dispatch(node.id, "onHover", .bool(hovering)) }
            })
            .modifier(ShellLongPress(enabled: node.handles("onLongPress")) {
                engine.dispatch(node.id, "onLongPress", ["modifiers": [:], "x": 0, "y": 0])
            })
            .modifier(ShellDragSource(item: node.props["draggable"]))
            .modifier(ShellDropTarget(node: node, engine: engine, targeted: $dropTargeted))
            .modifier(ShellContextMenu(items: node.props["contextMenu"]?.array) { id in
                engine.dispatch(node.id, "onContextMenuSelect", .string(id))
            })
            .modifier(ShellPan(enabled: node.handles("onPan"), panning: $panning) { payload in
                engine.dispatch(node.id, "onPan", payload)
            })
            .modifier(ShellMouseMove(enabled: node.handles("onMouseMove")) { payload in
                engine.dispatch(node.id, "onMouseMove", payload)
            })
            .modifier(ShellMagnify(enabled: node.handles("onMagnify")) { payload in
                engine.dispatch(node.id, "onMagnify", payload)
            })
            .modifier(ShellScrollWheel(nodeID: node.id, enabled: node.handles("onScrollWheel"), engine: engine))
            .modifier(ShellWindowDrag(enabled: node.bool("windowDrag")))
            .modifier(ShellCursor(name: node.style().cursor))
            .modifier(ShellTooltip(text: node.string("tooltip")))
            .modifier(ShellAccessibility(label: node.string("label"), role: node.string("role")))
    }
}

private struct ShellHover: ViewModifier {
    var enabled: Bool
    var onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled { content.onHover(perform: onChange) } else { content }
    }
}

/// Continuous pointer tracking over a node: every move, with the position
/// in the node's own coordinates, and one last event when the pointer leaves.
private struct ShellMouseMove: ViewModifier {
    var enabled: Bool
    var send: (ShellJSON) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    send(["x": .number(Double(point.x)), "y": .number(Double(point.y)), "inside": true])
                case .ended:
                    send(["x": 0, "y": 0, "inside": false])
                }
            }
        } else {
            content
        }
    }
}

/// Pinch (trackpad or touch).
private struct ShellMagnify: ViewModifier {
    var enabled: Bool
    var send: (ShellJSON) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                MagnifyGesture()
                    .onChanged { value in send(["phase": "changed", "scale": .number(Double(value.magnification))]) }
                    .onEnded { value in send(["phase": "ended", "scale": .number(Double(value.magnification))]) }
            )
        } else {
            content
        }
    }
}

/// Scroll-wheel / two-finger scroll over a node. The events are observed by
/// one monitor per app (`ShellRouter`), which needs to know which nodes care.
private struct ShellScrollWheel: ViewModifier {
    let nodeID: Int
    var enabled: Bool
    let engine: ShellEngine

    func body(content: Content) -> some View {
        content
            .onAppear { if enabled { engine.scrollWheelNodes.insert(nodeID) } }
            .onChange(of: enabled) { _, on in
                if on { engine.scrollWheelNodes.insert(nodeID) } else { engine.scrollWheelNodes.remove(nodeID) }
            }
            .onDisappear { engine.scrollWheelNodes.remove(nodeID) }
    }
}

private struct ShellLongPress: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.onLongPressGesture(perform: action) } else { content }
    }
}

private struct ShellTooltip: ViewModifier {
    var text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.help(text) } else { content }
    }
}

private struct ShellAccessibility: ViewModifier {
    var label: String?
    var role: String?

    func body(content: Content) -> some View {
        if label != nil || role != nil {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(label ?? ""))
                .accessibilityAddTraits(traits)
        } else {
            content
        }
    }

    private var traits: AccessibilityTraits {
        switch role {
        case "button", "tab": return .isButton
        case "image": return .isImage
        case "header": return .isHeader
        default: return []
        }
    }
}

private struct ShellCursor: ViewModifier {
    var name: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        switch name {
        case "pointer": content.pointerStyle(.link)
        case "text": content.pointerStyle(.horizontalText)
        case "resizeLeftRight": content.pointerStyle(.columnResize)
        case "resizeUpDown": content.pointerStyle(.rowResize)
        case "grab": content.pointerStyle(.grabIdle)
        default: content
        }
        #else
        content
        #endif
    }
}

private struct ShellWindowDrag: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        if enabled {
            // Only the top strip of the window is draggable by default
            // (`MoveBlockingView`); this makes the region draggable anywhere.
            content
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ShellPan: ViewModifier {
    var enabled: Bool
    @Binding var panning: Bool
    var send: (ShellJSON) -> Void

    private func payload(_ phase: String, _ value: DragGesture.Value) -> ShellJSON {
        [
            "phase": .string(phase),
            "dx": .number(Double(value.translation.width)),
            "dy": .number(Double(value.translation.height)),
            "vx": .number(Double(value.velocity.width)),
            "vy": .number(Double(value.velocity.height)),
        ]
    }

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !panning {
                            panning = true
                            send(payload("began", value))
                        }
                        send(payload("changed", value))
                    }
                    .onEnded { value in
                        panning = false
                        send(payload("ended", value))
                    }
            )
        } else {
            content
        }
    }
}

// MARK: - Menus

/// Menu entries from the JSON a branch supplies (see `MenuItem` in wowser.d.ts).
struct ShellMenuItems: View {
    let items: [ShellJSON]
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            entry(item)
        }
    }

    @ViewBuilder
    private func entry(_ item: ShellJSON) -> some View {
        let title = item["title"]?.string ?? ""
        let id = item["id"]?.string ?? title
        if item["separator"]?.bool == true {
            Divider()
        } else if let children = item["children"]?.array {
            Menu(title) {
                ShellMenuItems(items: children, onSelect: onSelect)
            }
        } else if item["checked"]?.bool == true {
            Toggle(title, isOn: Binding(get: { true }, set: { _ in onSelect(id) }))
                .disabled(item["disabled"]?.bool == true)
        } else {
            Button(role: item["destructive"]?.bool == true ? .destructive : nil, action: { onSelect(id) }) {
                if let icon = item["icon"]?.string {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
            }
            .disabled(item["disabled"]?.bool == true)
        }
    }
}

private struct ShellContextMenu: ViewModifier {
    var items: [ShellJSON]?
    var onSelect: (String) -> Void

    func body(content: Content) -> some View {
        if let items, !items.isEmpty {
            content.contextMenu { ShellMenuItems(items: items, onSelect: onSelect) }
        } else {
            content
        }
    }
}

#if os(macOS)
/// Native pop-up menus for `menus.show()` and `<Menu>` on macOS.
enum ShellMenus {
    private final class Target: NSObject {
        var chosen: String?
        @objc func pick(_ sender: NSMenuItem) {
            chosen = sender.representedObject as? String
        }
    }

    private static func build(_ items: [ShellJSON], target: Target) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item["separator"]?.bool == true {
                menu.addItem(.separator())
                continue
            }
            let title = item["title"]?.string ?? ""
            let entry = NSMenuItem(title: title, action: #selector(Target.pick(_:)), keyEquivalent: "")
            entry.target = target
            entry.representedObject = item["id"]?.string ?? title
            entry.isEnabled = item["disabled"]?.bool != true
            entry.state = item["checked"]?.bool == true ? .on : .off
            if let icon = item["icon"]?.string {
                entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            }
            if let children = item["children"]?.array {
                entry.submenu = build(children, target: target)
                entry.action = nil
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// Show a menu and return the chosen item's id. `at` is in the shell's
    /// root coordinate space (top-left origin); nil means at the pointer.
    /// Blocks until the menu closes, like any AppKit pop-up.
    static func popUp(items: [ShellJSON], at point: CGPoint?, in window: NSWindow?) -> String? {
        guard let window, let view = window.contentView, !items.isEmpty else { return nil }
        let target = Target()
        let menu = build(items, target: target)
        var windowPoint = window.mouseLocationOutsideOfEventStream
        if let point {
            windowPoint = CGPoint(x: point.x, y: view.bounds.height - point.y)
        }
        menu.popUp(positioning: nil, at: view.convert(windowPoint, from: nil), in: view)
        return target.chosen
    }
}
#endif

// MARK: - Drag and drop

enum ShellDrag {
    /// Matches `ProfileDotView.profileDragPrefix`: a space being dragged.
    static let spacePrefix = "wowser-profile-drag:"

    static func provider(_ item: ShellJSON) -> NSItemProvider {
        switch item["type"]?.string {
        case "tab":
            let id = ID<Tab>(raw: item["id"]?.string ?? "")
            // Same payload as a native sidebar row, so native drop targets
            // (split view, other windows, Finder for file tabs) accept it.
            return .tabDrag(tabID: id, fileURL: BrowserStore.shared.model.tabs[id]?.draggableFileURL)
        case "url":
            if let url = item["url"]?.string.flatMap({ URL(string: $0) }) {
                let provider = NSItemProvider(object: url as NSURL)
                provider.suggestedName = item["title"]?.string
                return provider
            }
            return NSItemProvider()
        case "space":
            return NSItemProvider(object: (spacePrefix + (item["id"]?.string ?? "")) as NSString)
        default:
            return NSItemProvider(object: (item["text"]?.string ?? "") as NSString)
        }
    }

    static func contentTypes(_ dropTypes: [String]) -> [UTType] {
        var out: [UTType] = []
        for type in dropTypes {
            switch type {
            case "tab", "text", "space": out.append(.text)
            case "url": out.append(.url)
            case "file": out.append(.fileURL)
            case "image": out.append(.image)
            default: break
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.identifier).inserted }
    }
}

private struct ShellDragSource: ViewModifier {
    var item: ShellJSON?

    func body(content: Content) -> some View {
        if let item, item["type"]?.string != nil {
            content.onDrag { ShellDrag.provider(item) }
        } else {
            content
        }
    }
}

private struct ShellDropTarget: ViewModifier {
    let node: ShellNode
    let engine: ShellEngine
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let types = node.props["dropTypes"]?.array?.compactMap(\.string), !types.isEmpty {
            content.onDrop(of: ShellDrag.contentTypes(types), isTargeted: $targeted) { providers, location in
                handle(providers, at: location, accepting: Set(types))
            }
        } else {
            content
        }
    }

    /// Item providers load asynchronously, so the drop is accepted up front
    /// and `onDrop` is delivered once the payload is in hand.
    private func handle(_ providers: [NSItemProvider], at location: CGPoint, accepting: Set<String>) -> Bool {
        let size = node.frame?.size ?? .zero
        let nodeID = node.id
        let engine = self.engine
        func deliver(_ fields: [String: ShellJSON]) {
            var payload = fields
            payload["x"] = .number(Double(location.x))
            payload["y"] = .number(Double(location.y))
            payload["width"] = .number(Double(size.width))
            payload["height"] = .number(Double(size.height))
            DispatchQueue.main.async {
                engine.dispatch(nodeID, "onDrop", .object(payload))
            }
        }

        if accepting.contains("tab"), let provider = providers.first(where: { $0.isTabDrag }) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                if let string { deliver(["type": "tab", "id": .string(string)]) }
            }
            return true
        }
        let foreign = providers.filter { !$0.isTabDrag }
        if accepting.contains("file"), let provider = foreign.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { deliver(["type": "file", "path": .string(url.path)]) }
            }
            return true
        }
        if accepting.contains("url"), let provider = foreign.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { deliver(["type": "url", "url": .string(url.absoluteString)]) }
            }
            return true
        }
        if accepting.contains("image"), let provider = foreign.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("shell-drop-\(UUID().uuidString).img")
                if (try? data.write(to: file)) != nil { deliver(["type": "image", "path": .string(file.path)]) }
            }
            return true
        }
        if accepting.contains("text") || accepting.contains("space"),
           let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                if string.hasPrefix(ShellDrag.spacePrefix) {
                    if accepting.contains("space") {
                        deliver(["type": "space", "id": .string(String(string.dropFirst(ShellDrag.spacePrefix.count)))])
                    }
                } else if accepting.contains("text") {
                    deliver(["type": "text", "text": .string(string)])
                }
            }
            return true
        }
        return false
    }
}
