import AppKit

public class CallbackMenuItem: NSMenuItem {
    private var callback: (() -> Void)?
    
    convenience init(title: String, callback: @escaping () -> Void) {
        self.init(title: title, action: #selector(performCallback), keyEquivalent: "")
        self.callback = callback
        self.target = self
    }
    
    @objc private func performCallback() {
        callback?()
    }
}
