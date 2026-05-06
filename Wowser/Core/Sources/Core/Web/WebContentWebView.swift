import WebKit
import QuartzCore

public class WebContentWebView: WKWebView {
    var onDarkModeChanged: ((Bool) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    
    var shrunk: Bool = false {
        didSet {
            if shrunk != oldValue {
                if !shrunk {
                    // Create a transform that scales about the center point
                    let bounds = self.bounds
                    let centerX = bounds.width / 2.0
                    let centerY = bounds.height / 2.0
                    
                    // Starting transform (tiny scale)
                    var startTransform = CATransform3DIdentity
                    // Translate to origin
                    startTransform = CATransform3DTranslate(startTransform, centerX, centerY, 0)
                    // Scale
                    startTransform = CATransform3DScale(startTransform, 0.001, 0.001, 1.0)
                    // Translate back
                    startTransform = CATransform3DTranslate(startTransform, -centerX, -centerY, 0)
                    
                    // Ending transform (normal scale)
                    let endTransform = CATransform3DIdentity
                    
                    // Apply initial transform
                    crossPlatformLayer.transform = startTransform
                    
                    // Create animation with niceDefault timing curve
                    let animation = CABasicAnimation(keyPath: "transform")
                    animation.fromValue = startTransform
                    animation.toValue = endTransform
                    animation.duration = 0.3
                    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0) // Same as niceDefault
                    animation.fillMode = .forwards
                    animation.isRemovedOnCompletion = true
                    
                    // Apply animation
                    crossPlatformLayer.add(animation, forKey: "showTransform")
                    crossPlatformLayer.transform = endTransform
                } else {
                    // Create a transform that scales about the center point
                    let bounds = self.bounds
                    let centerX = bounds.width / 2.0
                    let centerY = bounds.height / 2.0
                    
                    // Tiny scale transform
                    var transform = CATransform3DIdentity
                    // Translate to origin
                    transform = CATransform3DTranslate(transform, centerX, centerY, 0)
                    // Scale
                    transform = CATransform3DScale(transform, 0.001, 0.001, 1.0)
                    // Translate back
                    transform = CATransform3DTranslate(transform, -centerX, -centerY, 0)
                    
                    // Set immediately when hiding
                    crossPlatformLayer.transform = transform
                }
            }
        }
    }

    #if os(iOS)
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection){
            onDarkModeChanged?(traitCollection.userInterfaceStyle == .dark)
        }
    }
    
    public override var canBecomeFirstResponder: Bool {
        return true
    }
    
    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onBecomeFirstResponder?()
        }
        return result
    }
    #endif
    
    #if os(macOS)
    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        print("[WebContentWebView] willOpenMenu — \(menu.items.count) item(s)")
        for (idx, item) in menu.items.enumerated() {
            let identifier = item.identifier?.rawValue ?? "<nil>"
            let title = item.title
            let represented = item.representedObject.map { String(describing: $0) } ?? "<nil>"
            print("[WebContentWebView]   [\(idx)] id=\(identifier) title=\"\(title)\" representedObject=\(represented)")
        }
    }

    public override func layout() {
        super.layout()
        wantsLayer = true
        darkMode = NSAppearance.currentDrawing().name == .darkAqua
    }
    
    // TODO: this only works when we focus the text view
    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onBecomeFirstResponder?()
        }
        return result
    }
    
    private var darkMode = false {
        didSet {
            if darkMode != oldValue {
                onDarkModeChanged?(darkMode)
            }
        }
    }
    #endif
    
}
