#if os(macOS)
import AppKit
import WebKit

/// An offscreen, never-visible NSWindow that agent-driven background ("ghost")
/// webviews are parked in so they behave like real tabs.
///
/// A `WKWebView` that isn't in any window has a zero-sized viewport: layout
/// collapses (`innerWidth == 0`, every `getBoundingClientRect()` is 0×0),
/// `takeSnapshot` yields an empty image, and coordinate-based input has nothing
/// to hit. Mounting the view here — at a fixed laptop-ish size, in an ordered
/// window positioned far outside every screen — gives WebKit a real viewport
/// and a live layer tree, so `content.screenshot`, `page.click(x, y)` and
/// friends work for tabs the user never sees.
///
/// When the user activates a staged tab, the regular `EngineViewContainer`
/// calls `addSubview`, which reparents the webview out of here automatically.
@MainActor
final class AgentStageWindow {
    static let shared = AgentStageWindow()

    /// Viewport every staged webview gets. Matches a common laptop content area
    /// so screenshots look like what a user would see.
    static let viewportSize = NSSize(width: 1280, height: 800)

    private var window: NSWindow?
    private var sweepTimer: Timer?

    private init() {}

    /// True if `view` is currently parked on the stage.
    func contains(_ view: NSView) -> Bool {
        guard let content = window?.contentView else { return false }
        return view.superview === content
    }

    /// Mount `view` on the stage unless it's already in some window (e.g. the
    /// user is looking at it). Returns true if the view is renderable after
    /// this call (in any window).
    @discardableResult
    func ensureRenderable(_ view: NSView) -> Bool {
        if view.window != nil { return true }
        let win = ensureWindow()
        guard let content = win.contentView else { return false }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        // Order matters: WebKit computes its activity state (which drives
        // `document.visibilityState`, rAF and timer throttling) when the view
        // joins a window, and the occlusion flag is read at that moment. Set
        // it first, then mount.
        if let wk = view as? WKWebView {
            Self.disableOcclusionDetection(wk)
        }
        content.addSubview(view)
        // Belt and braces: a hide/unhide cycle makes WebKit recompute activity
        // state even if it cached "occluded" from an earlier mount.
        view.isHidden = true
        view.isHidden = false
        startSweepIfNeeded()
        return true
    }

    /// Release panes whose agent lease expired: clear the flag and, if their
    /// webview is parked here (not in a real window), unmount it so the page
    /// goes back to ordinary background-tab behaviour.
    func sweepExpiredLeases(now: Date = Date()) {
        var released: [ID<WebContent>] = []
        BrowserStore.shared.modify { st in released = st.sweepExpiredAgentUse(now: now) }
        for id in released {
            if let wc = BrowserStore.shared.liveWebContent(forId: id) { unmount(wc.view) }
        }
    }

    private func startSweepIfNeeded() {
        guard sweepTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AgentStageWindow.shared.sweepExpiredLeases() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    /// Remove `view` from the stage if it's parked here. Safe to call for any
    /// view.
    func unmount(_ view: NSView) {
        if contains(view) { view.removeFromSuperview() }
    }

    // MARK: - Internals

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        // Far outside any plausible display arrangement. AppKit clamps nothing
        // for borderless windows, so this is genuinely offscreen.
        let frame = NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: Self.viewportSize)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isExcludedFromWindowsMenu = true
        win.ignoresMouseEvents = true
        win.hidesOnDeactivate = false
        win.hasShadow = false
        win.isOpaque = true
        win.backgroundColor = .white
        win.title = "Agent Stage"
        // Keep it out of Mission Control / Exposé / window cycling, and pinned
        // so Spaces changes don't drag it around.
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        win.level = .normal
        win.contentView = NSView(frame: NSRect(origin: .zero, size: Self.viewportSize))
        // Ordering the window is what makes AppKit (and therefore WebKit)
        // treat its views as visible. `orderBack` never steals key/main status.
        win.orderBack(nil)
        window = win
        return win
    }

    /// WebKit pauses rendering for views it believes are occluded. The stage is
    /// offscreen, which the window server can report as occluded — so opt the
    /// view out of that check via SPI (`_windowOcclusionDetectionEnabled`).
    /// Falls back to a no-op if the selector is missing.
    private static func disableOcclusionDetection(_ webview: WKWebView) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webview.responds(to: sel), let imp = webview.method(for: sel) else { return }
        // `perform(_:with:)` can't pass a primitive BOOL, so call the IMP directly.
        typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: Fn.self)(webview, sel, ObjCBool(false))
    }

}
#endif
