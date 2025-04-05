import AppKit
import Core

class BrowserWindowController: NSWindowController {
    private var observers = [Any]()
    private var firstResponderObserver: NSKeyValueObservation?
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        self.window?.isMovableByWindowBackground = true
        
//        // Observe window's first responder changes
//        firstResponderObserver = window?.observe(\.firstResponder, options: [.new, .old]) { [weak self] window, change in
//            if let newResponder = change.newValue ?? nil {
//                print("First responder changed to: \(type(of: newResponder)) - \(newResponder)")
//                
//                // If it's a WebContentWebView, log additional details
////                if let webView = newResponder as? WKWebView {
////                    print("WebView became first responder: \(webView) - URL: \(webView.url?.absoluteString ?? "none")")
////                }
//            }
//        }
        
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
