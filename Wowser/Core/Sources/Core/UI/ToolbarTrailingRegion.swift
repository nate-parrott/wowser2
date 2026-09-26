import SwiftUI
#if os(macOS)
import AppKit
#endif

// The customizable cluster of buttons on the trailing edge of a web tab's
// toolbar. Order / custom buttons come from `BrowserState.toolbar`
// (BrowserState+Toolbar.swift). Right-clicking the region opens the
// customizer popover (ToolbarCustomizer.swift); while it's open every item
// in the bar is shown (eligible or not), wobbling, and non-interactive.

struct ToolbarTrailingRegion: View {
    var webContentID: ID<WebContent>?
    var snapshot: ToolbarViewSnapshot
    var openNativeTabInOtherType: (NativePageKey) -> Void

    @Environment(\.windowID) private var windowID
    @ObservedObject private var devModeStore = DevModeStore.shared
    @State private var customizing = false
    #if os(macOS)
    @State private var presenter = ToolbarCustomizerPresenter()
    #endif

    private let browserStore = BrowserStore.shared

    var body: some View {
        WithSnapshotMain(store: browserStore, snapshot: { $0.toolbarConfig }) { config in
            HStack(spacing: 0) {
                nativeItems

                let bar = config.barItems
                ForEach(Array(bar.enumerated()), id: \.element.key) { idx, ref in
                    if customizing {
                        item(ref, config: config)
                            .allowsHitTesting(false)
                            .modifier(WobbleModifier(active: true, seed: idx))
                    } else if isEligible(ref) {
                        item(ref, config: config)
                    }
                }

                // Right-click target when the bar is empty.
                Color.clear.frame(width: bar.isEmpty ? 30 : 0, height: UIConstants.macHeaderHeight)
            }
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .animation(.niceDefault, value: config.order)
            #if os(macOS)
            .background(RightClickCatcher { anchor in showCustomizer(from: anchor) })
            .onDisappear { presenter.close() }
            #endif
        }
    }

    #if os(macOS)
    private func showCustomizer(from anchor: NSView) {
        guard !customizing else { return }
        customizing = true
        presenter.onClose = { customizing = false }
        presenter.show(
            ToolbarCustomizerPopover(windowID: windowID, close: { presenter.close() }),
            from: anchor
        )
    }
    #endif

    // MARK: Eligibility

    private var devModeDomain: String? {
        guard snapshot.nativeKey == nil, !snapshot.isEmptyPage else { return nil }
        return DevModeStore.domain(for: snapshot.url)
    }

    private func isEligible(_ ref: ToolbarItemRef) -> Bool {
        switch ref {
        case .custom:
            return snapshot.nativeKey == nil
        case .builtin(let item):
            switch item {
            case .dictation: return true
            case .cleanMode: return snapshot.nativeKey == nil
            case .mobileViewport: return devModeDomain.map { devModeStore.isEnabled(for: $0) } ?? false
            case .bookmark: return true
            case .openChat: return snapshot.canOpenChat
            case .closePane: return snapshot.hasMultiplePanes
            case .newSplitPane: return snapshot.isLastPane
            }
        }
    }

    // MARK: Items

    @ViewBuilder private var nativeItems: some View {
        if let nativeKey = snapshot.nativeKey {
            #if os(macOS)
            if case .fileBrowser(let path) = nativeKey, let path, !path.isEmpty {
                FileBrowserToolbarItems(path: path, nativeKey: nativeKey, openInOtherType: openNativeTabInOtherType)
            } else {
                OpenInOtherNativeMenu(currentKey: nativeKey, openInOtherType: openNativeTabInOtherType)
            }
            #endif
        }
    }

    @ViewBuilder private func item(_ ref: ToolbarItemRef, config: ToolbarConfig) -> some View {
        switch ref {
        case .custom(let id):
            if let button = config.customButton(id: id) {
                CustomToolbarButtonView(button: button, webContentID: webContentID)
            }
        case .builtin(let item):
            builtin(item)
        }
    }

    @ViewBuilder private func builtin(_ item: ToolbarTrailingItem) -> some View {
        switch item {
        case .dictation:
            #if os(macOS)
            DictationButton(paneID: webContentID, emptyPage: false, fgColor: nil)
            #else
            placeholder(item)
            #endif
        case .cleanMode:
            if let webContentID {
                CleanModeStatusButton(webContentID: webContentID)
            } else {
                placeholder(item)
            }
        case .mobileViewport:
            if let devDomain = devModeDomain {
                let mobile = devModeStore.config(for: devDomain).mobile
                Button(action: { devModeStore.modify(devDomain) { $0.mobile.toggle() } }) {
                    Image(systemName: mobile ? "iphone.gen3" : "iphone.gen3.slash")
                        .imageScale(.medium)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help(mobile ? "Turn off mobile viewport" : "Turn on mobile viewport")
            } else {
                placeholder(item)
            }
        case .bookmark:
            BookmarkToolbarButton(webContentID: webContentID, url: snapshot.url)
        case .openChat:
            Button(action: openChatSplit) {
                Image(systemName: "bubble.left")
                    .imageScale(.medium)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Open chat in split view")
        case .closePane:
            Button(action: closeCurrentSplitPane) {
                Image(systemName: "xmark")
                    .imageScale(.medium)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Close pane")
        case .newSplitPane:
            Button(action: addSplitPane) {
                Image(systemName: "plus")
                    .imageScale(.medium)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("New split pane")
        }
    }

    /// Stand-in glyph for an ineligible built-in while customizing.
    private func placeholder(_ item: ToolbarTrailingItem) -> some View {
        Button(action: {}) {
            Image(systemName: item.icon).imageScale(.medium)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(item.title)
    }

    // MARK: Actions

    private func openChatSplit() {
        if let windowID {
            AgentChatTabs.openChatSplit(windowID: windowID)
        }
    }

    private func closeCurrentSplitPane() {
        guard let webContentID else { return }
        browserStore.close(webContentId: webContentID, removeIfPinned: true)
    }

    private func addSplitPane() {
        guard let windowID else { return }
        browserStore.createTab(withURL: nil, in: windowID, activate: true, inCurrentSplit: true)
    }

}

// MARK: - Buttons

private struct BookmarkToolbarButton: View {
    var webContentID: ID<WebContent>?
    var url: URL?
    @State private var isBookmarked = false

    var body: some View {
        Button(action: toggleBookmark) {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .imageScale(.medium)
                .help(isBookmarked ? "Remove Bookmark (⇧⌘D)" : "Add Bookmark (⇧⌘D)")
        }
        .buttonStyle(ToolbarButtonStyle())
        .disabled(url == nil)
        .onReceive(ArchiveStore.shared.publisher.map({ $0.isBookmarked(url: url) }).removeDuplicates().receive(on: DispatchQueue.main), perform: { self.isBookmarked = $0 })
    }

    private func toggleBookmark() {
        guard let webContentID else { return }
        guard let tabInfo = BrowserStore.shared.model.tabInfo(forWebContentId: webContentID) else { return }
        ArchiveStore.shared.toggleBookmark(url: tabInfo.url, title: tabInfo.title)
    }
}

/// A user-created button: runs its BrowserJS (or spawns an agent) on click.
private struct CustomToolbarButtonView: View {
    var button: CustomToolbarButton
    var webContentID: ID<WebContent>?
    @Environment(\.windowID) private var windowID

    var body: some View {
        Button(action: click) {
            Image(systemName: button.icon)
                .imageScale(.medium)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(button.label)
    }

    private func click() {
        guard let windowID else { return }
        ToolbarButtonRunner.click(buttonID: button.id, webContentID: webContentID, windowID: windowID)
    }
}

struct BarItemFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

#if os(macOS)
// MARK: - Popover presenter

/// Shows a SwiftUI view in an `NSPopover` that does NOT dismiss when the user
/// clicks outside it (`.applicationDefined`); the content closes it itself.
@MainActor
final class ToolbarCustomizerPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    var onClose: (() -> Void)?

    func show<Content: View>(_ content: Content, from view: NSView) {
        close()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: ToolbarCustomizerPopover.width, height: ToolbarCustomizerPopover.height)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        if !popover.isShown { close() }
    }

    func close() {
        guard let popover else { return }
        self.popover = nil
        popover.close()
        onClose?()
    }

    func popoverDidClose(_ notification: Notification) {
        guard popover != nil else { return }
        popover = nil
        onClose?()
    }
}
#endif

// MARK: - Wobble

/// Springboard-style jiggle while the toolbar is being customized. `seed`
/// staggers neighbours so they don't move in lockstep. A `repeatForever`
/// animation can't be cancelled once running, so the wobbling view is
/// recreated (via `.id`) whenever `active` flips.
struct WobbleModifier: ViewModifier {
    var active: Bool
    var seed: Int

    func body(content: Content) -> some View {
        Group {
            if active {
                content.modifier(WobbleAnimation(seed: seed))
            } else {
                content
            }
        }
        .id(active)
    }
}

private struct WobbleAnimation: ViewModifier {
    var seed: Int
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(phase ? 3 : -3))
            .onAppear {
                let duration = 0.12 + Double(seed % 3) * 0.015
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true).delay(Double(seed % 4) * 0.03)) {
                    phase = true
                }
            }
    }
}

#if os(macOS)
// MARK: - Right-click catcher

/// Sits behind the region (never hit-testable itself) and watches the
/// window's event stream for secondary clicks (right / ctrl-click) that land
/// inside its bounds. Left clicks are untouched and reach the buttons above.
/// Also serves as the edit overlay's positioning anchor.
private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (NSView) -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        let v = RightClickCatcherView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

private final class RightClickCatcherView: NSView {
    var onRightClick: ((NSView) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard secondary else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.onRightClick?(self)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
#endif
