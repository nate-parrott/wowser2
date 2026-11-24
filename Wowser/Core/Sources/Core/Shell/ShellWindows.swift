import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

/// `<Window>` — part of a branch's UI drawn in its own native window: a
/// floating panel, a pop-out, or a borderless overlay above everything.
///
/// The node lives in the same tree and JS context as the rest of the UI; only
/// its children are hosted elsewhere. Mounting it shows the window, removing
/// it closes the window, and prop changes move / resize / restyle it.
struct ShellWindowPortalView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine

    #if os(macOS)
    @State private var controller = ShellPanelController()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { controller.show(node: node, engine: engine) }
            .onDisappear { controller.close() }
            .onChange(of: node.props) { _, _ in controller.update(node: node, engine: engine) }
    }
    #else
    var body: some View {
        // iOS has no free-floating windows: present the content as a sheet.
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: .constant(true), onDismiss: { engine.dispatch(node.id, "onClose") }) {
                ShellPortalContent(node: node, engine: engine)
            }
    }
    #endif
}

/// What a portal window shows: the node's children, with the same context
/// the main window gives its tree.
struct ShellPortalContent: View {
    let node: ShellNode
    let engine: ShellEngine

    var body: some View {
        ShellStackLayout(alignment: .center) {
            ShellChildren(node: node)
        }
        .environment(\.shellAxis, .stack)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(ShellCoordinateSpace.root))
        .font(.system(size: 13))
        .modifier(ShellWindowChrome(windowID: engine.windowID))
        .environment(engine)
        .environment(\.windowID, engine.windowID)
    }
}

#if os(macOS)
/// The scripted UI talks about the screen in one coordinate system: points
/// from the top-left corner of the primary display, y growing downwards
/// (AppKit's global coordinates grow upwards from its bottom-left).
enum ShellScreen {
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func topLeft(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    static func topLeft(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The panel itself. Becomes key when asked to (so text fields work) unless
/// it is click-through.
final class ShellPanel: NSPanel {
    var allowsKey = true
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Creates and keeps one `ShellPanel` in step with a `window` node.
final class ShellPanelController: NSObject, NSWindowDelegate {
    private var panel: ShellPanel?
    private weak var engine: ShellEngine?
    private var nodeID = 0
    private var placement: ShellJSON = .null
    private var closingFromCode = false

    func show(node: ShellNode, engine: ShellEngine) {
        guard panel == nil else {
            update(node: node, engine: engine)
            return
        }
        self.engine = engine
        nodeID = node.id
        let kind = node.string("kind") ?? "panel"
        let chromeless = node.props["chromeless"]?.bool ?? (kind != "window")

        var style: NSWindow.StyleMask = chromeless ? [.borderless] : [.titled, .closable]
        if kind != "window" { style.insert(.nonactivatingPanel) }
        if kind == "window" { style.insert(.miniaturizable) }
        if node.props["resizable"]?.bool ?? (kind == "window") { style.insert(.resizable) }
        if !chromeless, kind == "panel" { style.insert(.utilityWindow) }

        let panel = ShellPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: style, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = kind == "overlay" ? .none : .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.userClosed() }
        let hosting = NSHostingController(rootView: ShellPortalContent(node: node, engine: engine))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.panel = panel

        configure(panel, node: node, kind: kind, chromeless: chromeless)
        if let name = node.string("autosave"), !name.isEmpty {
            let key = "ShellPanel-\(engine.branch)-\(name)"
            if !panel.setFrameUsingName(key) { place(panel, node: node, engine: engine, kind: kind) }
            panel.setFrameAutosaveName(key)
        } else {
            place(panel, node: node, engine: engine, kind: kind)
        }
        placement = Self.placementKey(node)

        if node.props["activates"]?.bool ?? (kind == "window") {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Show without taking focus from the page.
            panel.orderFrontRegardless()
        }
    }

    func update(node: ShellNode, engine: ShellEngine) {
        guard let panel else { return }
        let kind = node.string("kind") ?? "panel"
        configure(panel, node: node, kind: kind, chromeless: node.props["chromeless"]?.bool ?? (kind != "window"))
        // Only move / resize when the branch asked for a different frame, so
        // a panel the user dragged stays where they put it.
        let key = Self.placementKey(node)
        if key != placement {
            placement = key
            place(panel, node: node, engine: engine, kind: kind)
        }
    }

    func close() {
        guard let panel else { return }
        closingFromCode = true
        // Drop the SwiftUI tree first so hosted web views are released cleanly.
        panel.contentViewController = nil
        panel.close()
        self.panel = nil
    }

    private func configure(_ panel: ShellPanel, node: ShellNode, kind: String, chromeless: Bool) {
        let clickThrough = node.bool("clickThrough")
        panel.title = node.string("title") ?? ""
        panel.isOpaque = !chromeless
        panel.backgroundColor = chromeless ? .clear : .windowBackgroundColor
        panel.hasShadow = node.props["shadow"]?.bool ?? (kind != "overlay")
        panel.ignoresMouseEvents = clickThrough
        panel.allowsKey = !clickThrough
        panel.becomesKeyOnlyIfNeeded = kind != "window"
        panel.isMovableByWindowBackground = node.props["movable"]?.bool ?? (kind == "panel")

        let floating = node.props["floating"]?.bool ?? (kind != "window")
        panel.isFloatingPanel = floating
        if kind == "overlay" {
            // Above other apps' windows and the Dock, below the menu bar's menus.
            panel.level = .statusBar
        } else {
            panel.level = floating ? .floating : .normal
        }
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if node.props["allSpaces"]?.bool ?? (kind == "overlay") { behavior.insert(.canJoinAllSpaces) }
        if kind == "overlay" { behavior.insert(.stationary) }
        panel.collectionBehavior = behavior
    }

    private static func placementKey(_ node: ShellNode) -> ShellJSON {
        var out: [String: ShellJSON] = [:]
        for key in ["x", "y", "width", "height", "anchor", "relativeTo", "inset"] {
            if let value = node.props[key] { out[key] = value }
        }
        return .object(out)
    }

    /// Frame from the node's `width`/`height` and either `x`/`y` (screen
    /// points from the top-left) or `anchor` within the screen / the browser
    /// window.
    private func place(_ panel: ShellPanel, node: ShellNode, engine: ShellEngine, kind: String) {
        let screen = engine.hostWindow?.screen ?? NSScreen.main
        guard let screen else { return }
        let full = screen.frame
        let relativeToWindow = node.string("relativeTo") == "window"
        let reference: NSRect = relativeToWindow ? (engine.hostWindow?.frame ?? screen.visibleFrame) : (kind == "overlay" ? full : screen.visibleFrame)

        let defaultSize = kind == "overlay" ? reference.size : NSSize(width: 380, height: 300)
        let width = CGFloat(node.double("width") ?? Double(defaultSize.width))
        let height = CGFloat(node.double("height") ?? Double(defaultSize.height))
        var origin: NSPoint
        if let x = node.double("x"), let y = node.double("y") {
            // Global top-left coordinates → AppKit's bottom-left based.
            origin = NSPoint(x: CGFloat(x), y: ShellScreen.primaryTop - CGFloat(y) - height)
        } else {
            let anchor = ShellAlign.unitPoint(node.string("anchor") ?? "center")
            let inset = CGFloat(node.double("inset") ?? 0)
            let area = reference.insetBy(dx: inset, dy: inset)
            origin = NSPoint(
                x: area.minX + (area.width - width) * anchor.x,
                y: area.maxY - height - (area.height - height) * anchor.y
            )
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func frameJSON(_ panel: NSWindow) -> ShellJSON {
        let f = ShellScreen.topLeft(panel.frame)
        return ["x": .number(Double(f.minX)), "y": .number(Double(f.minY)), "width": .number(Double(f.width)), "height": .number(Double(f.height))]
    }

    private func userClosed() {
        engine?.dispatch(nodeID, "onClose")
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The branch decides: it hears `onClose` and removes the <Window>.
        userClosed()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, let engine, engine.tree.node(nodeID)?.handles("onFrame") == true else { return }
        engine.dispatch(nodeID, "onFrame", frameJSON(panel))
    }

    func windowDidResize(_ notification: Notification) {
        windowDidMove(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let engine, engine.tree.node(nodeID)?.handles("onFocus") == true else { return }
        engine.dispatch(nodeID, "onFocus")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let engine, engine.tree.node(nodeID)?.handles("onBlur") == true else { return }
        engine.dispatch(nodeID, "onBlur")
    }
}

/// System-wide hotkeys (Carbon `RegisterEventHotKey`): they fire while
/// another app is frontmost, and need no accessibility permission.
final class ShellGlobalHotkeys {
    static let shared = ShellGlobalHotkeys()

    private var nextID: UInt32 = 1
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Returns a token for `unregister`, or nil if the combination can't be
    /// registered (unknown key, or taken by the system / another app).
    func register(_ hotkey: ShellHotkey, action: @escaping () -> Void) -> UInt32? {
        guard let keyCode = Self.keyCodes[hotkey.key] else { return nil }
        installHandlerIfNeeded()
        var modifiers: UInt32 = 0
        if hotkey.cmd { modifiers |= UInt32(cmdKey) }
        if hotkey.shift { modifiers |= UInt32(shiftKey) }
        if hotkey.alt { modifiers |= UInt32(optionKey) }
        if hotkey.ctrl { modifiers |= UInt32(controlKey) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x574F_5753) /* 'WOWS' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == OSStatus(noErr), let ref else { return nil }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: id)
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == OSStatus(noErr) {
                let id = hotKeyID.id
                DispatchQueue.main.async { ShellGlobalHotkeys.shared.fire(id) }
            }
            return OSStatus(noErr)
        }, 1, &spec, nil, nil)
    }

    /// Virtual key codes (ANSI layout) for the names a hotkey string may use.
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
#endif
