import SwiftUI
#if os(macOS)
import AppKit
#endif

// The leaf node types: text, icons, images, scroll views, text input, menus,
// popovers, window controls, and live web content.

// MARK: - Text

struct ShellTextView: View {
    let node: ShellNode
    @Environment(\.shellFont) private var inherited
    @Environment(\.onAccentColor) private var onAccentColor

    var body: some View {
        let style = node.style()
        let font = inherited.merging(style)
        content(style)
            .font(font.font)
            .lineLimit(style.lineLimit)
            .truncationMode(truncation(style.truncate))
            .multilineTextAlignment(alignment(style.textAlign))
            .tracking(style.letterSpacing ?? 0)
            .lineSpacing(style.lineSpacing ?? 0)
            .modifier(ShellSelectable(enabled: style.selectable))
            .shellStyled(node)
    }

    private func content(_ style: ShellStyle) -> Text {
        var text: Text
        if let runs = node.props["runs"]?.array {
            let palette = ShellPalette(onAccent: onAccentColor)
            text = runs.reduce(Text(verbatim: "")) { partial, run in
                partial + Self.run(run, palette: palette)
            }
        } else {
            text = Text(verbatim: node.string("text") ?? "")
        }
        if style.underline { text = text.underline() }
        if style.strikethrough { text = text.strikethrough() }
        if style.monospacedDigits { text = text.monospacedDigit() }
        return text
    }

    private static func run(_ run: ShellJSON, palette: ShellPalette) -> Text {
        var text = Text(verbatim: run["text"]?.string ?? "")
        guard let raw = run["style"]?.object else { return text }
        let style = ShellStyle(raw: raw, state: [])
        if let weight = style.fontWeight { text = text.fontWeight(ShellFontSpec.weight(weight)) }
        if let size = style.fontSize { text = text.font(.system(size: size)) }
        if style.italic == true { text = text.italic() }
        if let color = palette.color(style.color) { text = text.foregroundColor(color) }
        if style.underline { text = text.underline() }
        if style.strikethrough { text = text.strikethrough() }
        return text
    }

    private func truncation(_ name: String?) -> Text.TruncationMode {
        switch name {
        case "middle": return .middle
        case "head": return .head
        default: return .tail
        }
    }

    private func alignment(_ name: String?) -> TextAlignment {
        switch name {
        case "center": return .center
        case "trailing": return .trailing
        default: return .leading
        }
    }
}

private struct ShellSelectable: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}

// MARK: - Icons and images

struct ShellIconView: View {
    let node: ShellNode

    var body: some View {
        let size = CGFloat(node.double("size") ?? 13)
        let weight = ShellFontSpec.weight(node.string("weight") ?? "regular")
        Image(systemName: node.string("name") ?? "questionmark")
            .symbolVariant(node.string("variant") == "fill" ? .fill : .none)
            .font(.system(size: size, weight: weight))
            .shellStyled(node)
    }
}

struct ShellFaviconView: View {
    let node: ShellNode

    var body: some View {
        let size = CGFloat(node.double("size") ?? 16)
        let page = node.string("url").flatMap { URL(string: $0) }
        let src = node.string("src").flatMap { URL(string: $0) } ?? page?.inferredFaviconURL
        FaviconView(faviconURL: src, size: size)
            .shellStyled(node)
    }
}

/// A tab's icon exactly as the native sidebar draws it.
struct ShellTabIconView: View {
    let node: ShellNode

    var body: some View {
        let id = ID<Tab>(raw: node.string("tabId") ?? "")
        let size = CGFloat(node.double("size") ?? 16)
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[id]?.appearance().icon }) { icon in
            // TabIconView draws at 16pt; scale for other sizes.
            TabIconView(icon: icon ?? .empty)
                .frame(width: 16, height: 16)
                .scaleEffect(size / 16)
                .frame(width: size, height: size)
        }
        .shellStyled(node)
    }
}

struct ShellImageView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @State private var loaded: UINSImage?
    @State private var loadedSrc: String?

    var body: some View {
        let src = node.string("src") ?? ""
        let fill = node.string("contentMode") == "fill"
        Group {
            if src.hasPrefix("http://") || src.hasPrefix("https://") {
                AsyncImage(url: URL(string: src)) { image in
                    styled(image, fill: fill)
                } placeholder: {
                    Color.clear
                }
            } else if src.hasPrefix("asset:") {
                styled(Image(String(src.dropFirst("asset:".count)), bundle: .module), fill: fill)
            } else if let loaded, loadedSrc == src {
                styled(Image(uinsImage: loaded), fill: fill)
            } else {
                Color.clear
            }
        }
        // Branch files are read off the main thread, never in `body`.
        .task(id: src) {
            guard !src.isEmpty, !src.contains(":") else { return }
            let branch = engine.branch
            let image = await Task.detached { () -> UINSImage? in
                guard let data = ShellBranchStore.shared.data(branch: branch, path: src) else { return nil }
                return UINSImage(data: data)
            }.value
            loaded = image
            loadedSrc = src
        }
        .shellStyled(node)
    }

    private func styled(_ image: Image, fill: Bool) -> some View {
        image
            .renderingMode(node.bool("template") ? .template : .original)
            .resizable()
            .aspectRatio(contentMode: fill ? .fill : .fit)
    }
}

extension Image {
    init(uinsImage: UINSImage) {
        #if os(macOS)
        self.init(nsImage: uinsImage)
        #else
        self.init(uiImage: uinsImage)
        #endif
    }
}

// MARK: - Scroll view

struct ShellScrollView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @State private var page: Int?

    var body: some View {
        let horizontal = node.string("axis") == "horizontal"
        let contentStyle = ShellStyle(raw: node.props["contentStyle"]?.object ?? [:], state: [])
        let showsIndicators = node.props["showsIndicators"]?.bool ?? true
        ScrollViewReader { proxy in
            Group {
                if node.bool("paging") {
                    ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                        pages(horizontal: horizontal)
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .onChange(of: page) { _, id in
                        if let id, let index = node.children.firstIndex(where: { $0.id == id }) {
                            engine.dispatch(node.id, "onPageChange", .number(Double(index)))
                        }
                    }
                    .onAppearOrChange(of: node.props["page"]?.int) { index in
                        if let index, let child = node.children.get(index), page != child.id { page = child.id }
                    }
                } else {
                    ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: showsIndicators) {
                        stack(horizontal: horizontal, style: contentStyle)
                            .padding(contentStyle.padding)
                            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .onChange(of: node.string("scrollTo")) { _, target in
                guard let target else { return }
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.3)) { proxy.scrollTo(target) }
            }
        }
        .shellStyled(node)
    }

    @ViewBuilder
    private func stack(horizontal: Bool, style: ShellStyle) -> some View {
        if horizontal {
            HStack(alignment: ShellAlign.vertical(style.align), spacing: style.gap ?? 0) { ShellChildren(node: node) }
                .environment(\.shellAxis, .row)
                .environment(\.shellStretch, style.align == "stretch")
        } else {
            VStack(alignment: ShellAlign.horizontal(style.align), spacing: style.gap ?? 0) { ShellChildren(node: node) }
                .environment(\.shellAxis, .column)
                .environment(\.shellStretch, style.align == "stretch")
        }
    }

    /// Each child is one page, as large as the scroll view.
    @ViewBuilder
    private func pages(horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 0) {
                ForEach(node.children) { child in
                    ShellNodeView(node: child).containerRelativeFrame(.horizontal).id(child.id)
                }
            }
            .scrollTargetLayout()
            .environment(\.shellAxis, .stack)
        } else {
            VStack(spacing: 0) {
                ForEach(node.children) { child in
                    ShellNodeView(node: child).containerRelativeFrame(.vertical).id(child.id)
                }
            }
            .scrollTargetLayout()
            .environment(\.shellAxis, .stack)
        }
    }
}

// MARK: - Text input

/// A text field that takes part in the app's keyboard-focus model
/// (`FocusTarget.shellInput`): while it is focused the page doesn't get
/// keystrokes, and when it blurs focus goes back where `focusState` says.
struct ShellTextInputView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @Environment(\.shellFont) private var inherited
    @Environment(\.onAccentColor) private var onAccentColor
    @State private var text = ""
    @State private var focusSnap = FocusSnap()

    private var focusTarget: FocusTarget {
        .shellInput(window: engine.windowID, key: "\(engine.generation):\(node.id)")
    }
    private var isFocused: Bool { focusSnap.target == focusTarget }

    var body: some View {
        let style = node.style()
        let font = inherited.merging(style)
        let palette = ShellPalette(onAccent: onAccentColor)
        let multiline = node.bool("multiline")
        let options = InputTextFieldOptions(
            placeholder: node.string("placeholder") ?? "",
            font: UINSFont.systemFont(ofSize: font.size, weight: Self.uiWeight(style.fontWeight)),
            color: palette.color(style.color).map { UINSColor($0) } ?? UINSColor.textColor,
            insets: .zero,
            placeholderColor: palette.color(style.placeholderColor).map { UINSColor($0) },
            wantsUpDownArrowEvents: node.handles("onKey"),
            selectAllOnFocus: node.bool("selectAllOnFocus"),
            lineLimit: multiline ? nil : 1
        )
        InputTextField(
            text: Binding(get: { text }, set: { changed($0) }),
            options: options,
            // Focus is state-driven: the field takes first responder when the
            // focus snap names it.
            focusDate: isFocused ? (focusSnap.date ?? .distantPast) : nil,
            focusTarget: focusTarget,
            onEvent: handle
        )
        .frame(minHeight: font.size + 6)
        .preference(key: ShellFocusWithinKey.self, value: isFocused)
        .onReceiveFocusSnap(windowID: engine.windowID) { focusSnap = $0 }
        .onAppearOrChange(of: node.string("value") ?? "") { value in
            if text != value { text = value }
        }
        .onAppear {
            let target = focusTarget
            engine.commandHandlers[node.id] = { name, _ in
                BrowserStore.shared.modify { state in
                    if name == "focus" { state.didFocus(target: target) }
                    if name == "blur" { state.didLoseFocus(target: target) }
                }
                return nil
            }
            if node.bool("autoFocus") {
                BrowserStore.shared.modify { $0.didFocus(target: target) }
            }
        }
        .onDisappear {
            let target = focusTarget
            engine.commandHandlers[node.id] = nil
            BrowserStore.shared.modify { $0.didLoseFocus(target: target) }
        }
        .shellStyled(node)
    }

    private func changed(_ value: String) {
        guard value != text else { return }
        text = value
        engine.dispatch(node.id, "onChangeText", .string(value))
        // Controlled: if JS kept a different value, show that.
        let accepted = node.string("value") ?? ""
        if accepted != text { text = accepted }
    }

    private func modifiers() -> ShellJSON {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return ["cmd": .bool(flags.contains(.command)), "shift": .bool(flags.contains(.shift)), "alt": .bool(flags.contains(.option)), "ctrl": .bool(flags.contains(.control))]
        #else
        return ["cmd": false, "shift": false, "alt": false, "ctrl": false]
        #endif
    }

    private func handle(_ event: TextFieldEvent) {
        let target = focusTarget
        switch event {
        case .key(let key):
            switch key {
            case .enter:
                engine.dispatch(node.id, "onSubmit", ["__args": [.string(text), ["modifiers": modifiers()]]])
            case .upArrow:
                engine.dispatch(node.id, "onKey", ["key": "up", "modifiers": modifiers()])
            case .downArrow:
                engine.dispatch(node.id, "onKey", ["key": "down", "modifiers": modifiers()])
            case .escape:
                engine.dispatch(node.id, "onKey", ["key": "escape", "modifiers": modifiers()])
            }
        case .focus:
            BrowserStore.shared.modify { $0.didFocus(target: target) }
            if node.handles("onFocus") { engine.dispatch(node.id, "onFocus") }
        case .blur:
            BrowserStore.shared.modify { $0.didLoseFocus(target: target) }
            if node.handles("onBlur") { engine.dispatch(node.id, "onBlur") }
        case .backspaceOnEmptyField:
            engine.dispatch(node.id, "onKey", ["key": "backspace", "modifiers": modifiers()])
        case .largePaste, .didPasteURL:
            break
        }
    }

    private static func uiWeight(_ name: String?) -> UINSFont.Weight {
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
}

// MARK: - Menu button and popover

struct ShellMenuButton: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @Environment(\.shellFont) private var inheritedFont

    var body: some View {
        let style = node.style()
        let items = node.props["items"]?.array ?? []
        #if os(macOS)
        // AppKit pop-up under the label: SwiftUI's Menu restyles custom labels.
        HStack(alignment: ShellAlign.vertical(style.align), spacing: style.gap ?? 0) {
            ShellChildren(node: node)
        }
        .environment(\.shellAxis, .row)
        .environment(\.shellFont, inheritedFont.merging(style))
        .shellStyled(node)
        .contentShape(Rectangle())
        .onTapGesture {
            var at: CGPoint?
            if let frame = node.frame { at = CGPoint(x: frame.minX, y: frame.maxY + 4) }
            if let id = ShellMenus.popUp(items: items, at: at, in: engine.hostWindow) {
                engine.dispatch(node.id, "onSelect", .string(id))
            }
        }
        #else
        Menu {
            ShellMenuItems(items: items) { id in engine.dispatch(node.id, "onSelect", .string(id)) }
        } label: {
            HStack(alignment: ShellAlign.vertical(style.align), spacing: style.gap ?? 0) {
                ShellChildren(node: node)
            }
            .environment(\.shellAxis, .row)
            .environment(\.shellFont, inheritedFont.merging(style))
            .shellStyled(node)
        }
        #endif
    }
}

struct ShellPopoverView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @Environment(\.onAccentColor) private var onAccentColor

    var body: some View {
        let edge: Edge
        switch node.string("edge") {
        case "top": edge = .top
        case "leading": edge = .leading
        case "trailing": edge = .trailing
        default: edge = .bottom
        }
        return Group {
            if let anchor = node.children.first {
                ShellNodeView(node: anchor)
                    .popover(isPresented: Binding(
                        get: { node.bool("open") },
                        set: { open in if !open { engine.dispatch(node.id, "onClose") } }
                    ), arrowEdge: edge) {
                        if let content = node.children.get(1) {
                            // A popover is its own window: hand the context over again.
                            ShellNodeView(node: content)
                                .environment(engine)
                                .environment(\.onAccentColor, onAccentColor)
                                .environment(\.windowID, engine.windowID)
                        }
                    }
            }
        }
        .shellStyled(node)
    }
}

// MARK: - Window controls and web content

struct ShellWindowControlsView: View {
    let node: ShellNode

    var body: some View {
        MacWindowControlsIfValidElse { EmptyView() }
            .shellStyled(node)
    }
}

/// The live page of one pane, with its native overlays (find bar, reader,
/// terminal, load failures…). No toolbar.
///
/// Three optional props turn it into a thumbnail, a pop-out or a cut-out:
/// - `viewport {width, height}`: the page lays out at this size and is scaled
///   to fit the node with a visual transform (no relayout as the node resizes).
/// - `crop {x, y, width, height}`: show only this rectangle of the page's
///   viewport, scaled to fit the node.
/// - `cropTo "css selector"`: like `crop`, but follows an element in the page
///   (tracked natively by `ShellPageWatcher`, no JS round-trip per frame).
///
/// A page lives in one `WKWebView`, so it shows in one place at a time: the
/// most recently mounted `<WebPane>` for a pane wins.
struct ShellWebPaneView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine
    @State private var trackedRect: CGRect?
    @State private var watchID: String?

    var body: some View {
        let paneID = ID<WebContent>(raw: node.string("paneId") ?? "")
        let selector = node.string("cropTo")
        Group {
            // Web contents are created on demand, the same way PaneView does it.
            if !paneID.raw.isEmpty,
               let webContent = BrowserStore.shared.getOrCreateWebContent(forId: paneID, toBeActiveInWindow: engine.windowID) {
                let page = WrappedWebView(webContent: webContent, shrunk: false)
                if let framing = ShellWebFraming(node: node, trackedRect: trackedRect) {
                    GeometryReader { geo in
                        let placed = framing.placement(in: geo.size)
                        page
                            .frame(width: placed.layout.width, height: placed.layout.height)
                            .scaleEffect(placed.scale, anchor: .topLeading)
                            .offset(x: placed.offset.x, y: placed.offset.y)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                            .clipped()
                    }
                } else {
                    page
                }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(node.props["interactive"]?.bool ?? true)
        .shellStyled(node)
        .task(id: ShellWebPaneWatchKey(paneID: paneID, selector: selector)) {
            stopWatching()
            guard let selector, !selector.isEmpty, !paneID.raw.isEmpty else { return }
            watchID = ShellPageWatcher.shared.watch(
                paneID: paneID,
                expression: ShellPageWatcher.elementRectExpression(selector: selector),
                throttleMs: 50
            ) { value in
                let rect = ShellWebFraming.rect(value)
                if rect != trackedRect { trackedRect = rect }
            }
        }
        .onDisappear { stopWatching() }
    }

    private func stopWatching() {
        if let watchID { ShellPageWatcher.shared.unwatch(watchID) }
        watchID = nil
        trackedRect = nil
    }
}

private struct ShellWebPaneWatchKey: Equatable {
    var paneID: ID<WebContent>
    var selector: String?
}

/// Where a page sits inside a `<WebPane>` that scales or crops it. Pure
/// geometry, so it can be tested without a web view.
struct ShellWebFraming: Equatable {
    var viewportWidth: CGFloat?
    var viewportHeight: CGFloat?
    var crop: CGRect?
    /// "fit" keeps the whole rectangle visible; "fill" covers the node.
    var fill = false

    struct Placement: Equatable {
        var layout: CGSize
        var scale: CGFloat
        var offset: CGPoint
    }

    init(viewportWidth: CGFloat? = nil, viewportHeight: CGFloat? = nil, crop: CGRect? = nil, fill: Bool = false) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.crop = crop
        self.fill = fill
    }

    /// nil when the node asks for none of this: the page is then shown as is.
    init?(node: ShellNode, trackedRect: CGRect?) {
        let viewport = node.props["viewport"]?.object
        viewportWidth = viewport?["width"]?.double.map { CGFloat($0) }
        viewportHeight = viewport?["height"]?.double.map { CGFloat($0) }
        crop = trackedRect ?? node.props["crop"].flatMap { Self.rect($0) }
        fill = node.string("cropFit") == "fill"
        if viewportWidth == nil, viewportHeight == nil, crop == nil { return nil }
    }

    static func rect(_ json: ShellJSON) -> CGRect? {
        guard let o = json.object, let w = o["width"]?.double, let h = o["height"]?.double, w >= 1, h >= 1 else { return nil }
        return CGRect(x: o["x"]?.double ?? 0, y: o["y"]?.double ?? 0, width: w, height: h)
    }

    func placement(in size: CGSize) -> Placement {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        // The size the page lays out at. With only one side given, the other
        // follows the node's shape, so the page fills the node exactly.
        var layout = CGSize(width: width, height: height)
        if let viewportWidth, let viewportHeight {
            layout = CGSize(width: viewportWidth, height: viewportHeight)
        } else if let viewportWidth {
            layout = CGSize(width: viewportWidth, height: height * viewportWidth / width)
        } else if let viewportHeight {
            layout = CGSize(width: width * viewportHeight / height, height: viewportHeight)
        }
        let shown = crop ?? CGRect(origin: .zero, size: layout)
        let sx = width / max(shown.width, 1)
        let sy = height / max(shown.height, 1)
        let scale = max(0.01, fill ? max(sx, sy) : min(sx, sy))
        // Centre what is shown in the node.
        let offset = CGPoint(
            x: (width - shown.width * scale) / 2 - shown.minX * scale,
            y: (height - shown.height * scale) / 2 - shown.minY * scale
        )
        return Placement(layout: layout, scale: scale, offset: offset)
    }
}
