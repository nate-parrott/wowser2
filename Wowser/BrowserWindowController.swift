import AppKit
import Core

class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private var observers = [Any]()
    private var firstResponderObserver: NSKeyValueObservation?
    private var windowControlsHacker: MacWindowControlsHacker?
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        self.window?.isMovableByWindowBackground = true
        
        // Setup window controls hacker
        if let window = self.window {
            windowControlsHacker = MacWindowControlsHacker(window: window)
            windowControlsHacker?.fullscreenChanged = { [weak self] isFullscreen in
                self?.isFullscreen = isFullscreen
            }
        }
        
        // Observe window's first responder changes
        firstResponderObserver = window?.observe(\.firstResponder, options: [.new, .old]) { [weak self] window, change in
            if let newResponder = change.newValue ?? nil {
                print("[First responder] \(type(of: newResponder)) - \(newResponder)")
            }
        }
        
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self.window!, queue: .main) { [weak self] _ in
            if let self {
                self.willClose()
                AppDelegate.shared.windowControllers.removeAll(where: { $0 === self })
            }
        })
        
        isFullscreen = windowControlsHacker?.isFullscreen ?? false
    }
    
    private(set) var isFullscreen: Bool = false {
        didSet {
            browserViewController?.rootHostingController?.rootView.isFullscreen = isFullscreen
        }
    }
    
    var browserViewController: BrowserViewController? {
        window?.contentViewController as? BrowserViewController
    }
    
    private func willClose() {
        self.browserViewController?.willClose()
        if let windowID = browserViewController?.windowID {
            BrowserStore.shared.modify { state in
                state.closeWindow(id: windowID)
            }
        }
    }
    
    deinit {
        print("BrowserWindowController deinit")
    }
}

// HACK: NSHostingController interacts weirdly with onDrag and doesn't clean up its subviews (including webviews) when being torn down.
// To force at least some cleanup, we need to 'finalize' the hosting view by forcing it to render
// with `unmount=true`, which causes it to render an empty view and release any attached webviews.
class BrowserNSWindow: NSWindow {
    private var wasClosed = false
    override func close() {
        if wasClosed {
            return
        }
        wasClosed = true
        if let content = contentViewController as? BrowserViewController, let hostController = content.rootHostingController {
            hostController.rootView.unmount = true
            DispatchQueue.main.async {
                super.close()
            }
            return
        }
        super.close()
    }
}
