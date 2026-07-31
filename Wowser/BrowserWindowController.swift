import AppKit
import Core
import Foundation

class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private var observers = [Any]()
    private var firstResponderObserver: NSKeyValueObservation?
    private var windowControlsHacker: MacWindowControlsHacker?
    
    override func windowDidLoad() {
        super.windowDidLoad()

        self.window?.isMovableByWindowBackground = true
        // Self is registered as window delegate so windowDidBecomeKey fires;
        // becoming-key bumps a state field that drives pane refocus.
        self.window?.delegate = self

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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let id = self.browserViewController?.windowID {
                self.observers.append(BrowserStore.shared.uiPublisher.map({ $0.focusState(windowID: id) }).removeDuplicates().sink(receiveValue: { s in
                    print("[First responder focus snap] \(s.target)")
                }))
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

    func windowDidBecomeKey(_ notification: Notification) {
        guard let windowID = browserViewController?.windowID else { return }
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.lastBecameKeyAt = Date()
        }
    }
}

// HACK: NSHostingController interacts weirdly with onDrag and doesn't clean up its subviews (including webviews) when being torn down.
// To force at least some cleanup, we need to 'finalize' the hosting view by forcing it to render
// with `unmount=true`, which causes it to render an empty view and release any attached webviews.
class BrowserNSWindow: NSWindow, SidebarFrameHostingWindow {
    private var wasClosed = false

    /// Set by SwiftUI Sidebar via SidebarFramePublisher. In SwiftUI's
    /// "BrowserWindowRoot" coordinate space (top-left origin).
    var sidebarFrameInWindow: CGRect?

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

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Arm split-drop targets *before* a potential tab drag starts —
            // AppKit decides drag destinations at drag-begin, so registration
            // must already be in place. Reset on every mouseDown so a missed
            // mouseUp (consumed inside AppKit's modal drag loop) doesn't leave
            // the gate stuck armed.
            NotificationCenter.default.post(name: .hideTabDropTargets, object: nil)
            if mouseDownIsOverSidebar(event: event) {
                NotificationCenter.default.post(name: .showTabDropTargets, object: nil)
            }
        case .leftMouseUp:
            NotificationCenter.default.post(name: .hideTabDropTargets, object: nil)
        default:
            break
        }
        super.sendEvent(event)
    }

    private func mouseDownIsOverSidebar(event: NSEvent) -> Bool {
        guard let frame = sidebarFrameInWindow,
              let bvc = contentViewController as? BrowserViewController,
              let hostingView = bvc.rootHostingController?.view else {
            return false
        }
        // Convert window-coord event location to the SwiftUI hosting view's
        // local coords. NSHostingView is flipped, so this lands in the same
        // top-left coord space the BrowserWindowRoot frame was measured in.
        let pt = hostingView.convert(event.locationInWindow, from: nil)
        return frame.contains(pt)
    }
}
