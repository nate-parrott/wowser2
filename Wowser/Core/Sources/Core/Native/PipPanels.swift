import SwiftUI
import Combine

#if os(macOS)
import AppKit

// MARK: - Panel manager

/// Owns the floating NSPanels for pip tabs. Purely reactive: observes
/// `BrowserState.openPips` and creates/destroys panels to match.
public final class PipPanelManager {
    public static let shared = PipPanelManager()

    private var panels: [ID<Tab>: PipPanel] = [:]
    private var subscriptions = Set<AnyCancellable>()

    public func start() {
        BrowserStore.shared.uiPublisher
            .map { $0.openPips }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pips in
                self?.sync(pips: pips)
            }
            .store(in: &subscriptions)
    }

    private func sync(pips: [PipDescriptor]) {
        let byID = Dictionary(uniqueKeysWithValues: pips.map { ($0.tabID, $0) })

        for (tabID, panel) in panels where byID[tabID] == nil {
            panels.removeValue(forKey: tabID)
            panel.tearDownAndClose()
        }

        for pip in pips {
            if let existing = panels[pip.tabID] {
                existing.update(descriptor: pip)
            } else {
                let panel = PipPanel(descriptor: pip)
                panels[pip.tabID] = panel
                panel.orderFrontRegardless()
            }
        }
    }
}

// MARK: - Panel

final class PipPanel: NSPanel, NSWindowDelegate {
    private(set) var descriptor: PipDescriptor
    private let hosting: NSHostingController<PipRootView>
    private var isTearingDown = false

    init(descriptor: PipDescriptor) {
        self.descriptor = descriptor
        self.hosting = NSHostingController(rootView: PipRootView(descriptor: descriptor))
        // Borderless: a titled window's (transparent) titlebar view sits above
        // the content view and interferes with clicks on our custom header.
        // We draw our own rounded corners; .resizable still gives edge-resize.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Must become key on click so Cmd+W (Close Tab targets the first
        // responder) hits our closeCurrentTab instead of the main window's.
        becomesKeyOnlyIfNeeded = false
        // The webview swallows mouse events, so in practice this makes the
        // header strip the drag region.
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow

        hosting.sizingOptions = []
        contentViewController = hosting

        if !setFrameUsingName("PipPanel-\(descriptor.tabID.raw)") {
            setContentSize(NSSize(width: 380, height: 560))
            center()
        }
        setFrameAutosaveName("PipPanel-\(descriptor.tabID.raw)")

        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func update(descriptor: PipDescriptor) {
        guard descriptor != self.descriptor else { return }
        self.descriptor = descriptor
        hosting.rootView = PipRootView(descriptor: descriptor)
    }

    /// Programmatic close driven by state sync. Unmounts the SwiftUI tree
    /// first so the hosted webview is released cleanly (NSHostingController
    /// doesn't tear down its subviews on window close — see BrowserNSWindow).
    func tearDownAndClose() {
        isTearingDown = true
        hosting.rootView = PipRootView(descriptor: descriptor, unmount: true)
        DispatchQueue.main.async {
            self.close()
        }
    }

    private func hidePip() {
        BrowserStore.shared.modify { state in
            state.setPipOpen(false, tabId: self.descriptor.tabID)
        }
    }

    /// Cmd+W: the main menu's Close Tab item targets this selector on the
    /// responder chain; when a pip panel is key it dismisses the pip without
    /// closing the tab (same as the header's x button).
    @objc func closeCurrentTab(_ sender: Any?) {
        hidePip()
    }

    override func performClose(_ sender: Any?) {
        hidePip()
    }

    override func cancelOperation(_ sender: Any?) {
        hidePip()
    }

    func windowWillClose(_ notification: Notification) {
        if !isTearingDown {
            hidePip()
        }
    }
}

// MARK: - SwiftUI content

struct PipRootView: View {
    var descriptor: PipDescriptor
    var unmount = false

    var body: some View {
        if !unmount {
            PipPanelView(descriptor: descriptor)
        }
    }
}

private struct PipContentSnapshot: Equatable {
    var pane: WindowSnapshot.PaneSnapshot
    var mobileViewport: Bool
    var title: String?
}

private struct PipPanelView: View {
    var descriptor: PipDescriptor

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state -> PipContentSnapshot? in
            guard let tab = state.tabs[descriptor.tabID], let pane = tab.panes.first else { return nil }
            return PipContentSnapshot(
                pane: WindowSnapshot.PaneSnapshot(
                    id: pane.id.raw,
                    webContentId: pane.id,
                    focused: true,
                    searchActive: false,
                    emptyPage: pane.info.isEmptyPage,
                    colorScheme: pane.info.colorScheme,
                    isPickingSelector: false,
                    weight: 1,
                    topbarLocked: false
                ),
                mobileViewport: pane.info.mobileViewport == true,
                title: tab.customTitle ?? pane.info.title
            )
        } main: { snapshot in
            if let snapshot {
                VStack(spacing: 0) {
                    PipHeader(
                        tabID: descriptor.tabID,
                        windowID: descriptor.windowID,
                        title: snapshot.title,
                        colorScheme: snapshot.pane.colorScheme
                    )
                    // The page lays out at a fixed logical width (400 for
                    // mobile-responsive pages, 900 otherwise) and is shrunk to
                    // fit with a pure visual transform — no page relayout on
                    // resize, unlike pageZoom.
                    GeometryReader { geo in
                        let logicalWidth: CGFloat = snapshot.mobileViewport ? 400 : 900
                        let scale = min(1, max(0.01, geo.size.width / logicalWidth))
                        PaneView(
                            snapshot: snapshot.pane,
                            singlePane: true,
                            topbarVisible: false,
                            toolbarColorScheme: snapshot.pane.colorScheme,
                            toolbarHidden: true
                        )
                        .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                        .scaleEffect(scale, anchor: .topLeading)
                    }
                }
                .withBrowserContext(windowID: descriptor.windowID, profileID: descriptor.profileID)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .ignoresSafeArea()
    }
}

/// Small draggable strip at the top of a pip panel, tinted like the command
/// bar. Close, expand, and the page title. Dragging the strip moves the
/// window (isMovableByWindowBackground).
private struct PipHeader: View {
    var tabID: ID<Tab>
    var windowID: ID<WindowState>
    var title: String?
    var colorScheme: ContentColorScheme?

    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 2) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .help("Close Pip")
            }
            .buttonStyle(TabAccessoryButtonStyle())

            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .help("Expand to Full Tab")
            }
            .buttonStyle(TabAccessoryButtonStyle())

            Text(title ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(0.8)
                .padding(.leading, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(colorScheme?.background.color ?? Color("Background", bundle: .module))
        .foregroundColor(colorScheme?.foreground.color)
        .contentShape(Rectangle())
    }

    private func dismiss() {
        BrowserStore.shared.modify { state in
            state.setPipOpen(false, tabId: tabID)
        }
    }

    private func expand() {
        BrowserStore.shared.modify { state in
            state.activate(tabId: tabID, in: windowID) // activate() clears pip mode
            state.unghostTab(id: tabID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

#endif
