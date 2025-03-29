import AppKit
import Core

class BrowserWindowController: NSWindowController {
    private var observers = [Any]()
    override func windowDidLoad() {
        super.windowDidLoad()
        
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
