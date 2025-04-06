import AppKit
import Core

class BrowserWindowController: NSWindowController {
    private var observers = [Any]()
    private var firstResponderObserver: NSKeyValueObservation?
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        self.window?.isMovableByWindowBackground = true
        
        // Observe window's first responder changes
        firstResponderObserver = window?.observe(\.firstResponder, options: [.new, .old]) { [weak self] window, change in
            if let newResponder = change.newValue ?? nil {
                print("[First responder] \(type(of: newResponder)) - \(newResponder)")
                
                // If it's a WebContentWebView, log additional details
//                if let webView = newResponder as? WKWebView {
//                    print("WebView became first responder: \(webView) - URL: \(webView.url?.absoluteString ?? "none")")
//                }
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self.window!, queue: .main) { [weak self] _ in
            if let self {
                self.willClose()
                AppDelegate.shared.windowControllers.removeAll(where: { $0 === self })
            }
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
    override func close() {
        if let content = contentViewController as? BrowserViewController, let hostController = content.rootHostingController, !hostController.rootView.unmount {
            hostController.rootView.unmount = true
            DispatchQueue.main.async {
                self.close()
            }
            return
        }
        super.close()
    }
}
