import SwiftUI

#if os(macOS)
import AppKit

public class MacWindowControlsHacker {
    private weak var window: NSWindow?
    private var observers = [Any]()
    private var originalControls: [NSButton?] = []
    
    public init(window: NSWindow) {
        self.window = window
        
        // Store array of original window controls
        let controlTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        originalControls = controlTypes.map { window.standardWindowButton($0) }
        
        // Register for fullscreen change notifications
        let nc = NotificationCenter.default
        let fsObserver = nc.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            self?.updateFullscreenState(true)
        }
        
        let exitFsObserver = nc.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            self?.updateFullscreenState(false)
        }
        
        observers = [fsObserver, exitFsObserver]
        
        updateFullscreenState(false)
    }
    
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // Provide this notif so our SwiftUI views can hide/show their own window controls view
    public var fullscreenChanged: ((Bool) -> Void)?
    
    private func updateFullscreenState(_ isFullscreen: Bool) {
        // Show/hide original window controls
        for control in originalControls {
            control?.isHidden = !isFullscreen
        }
        
        // Call callback
        fullscreenChanged?(isFullscreen)
    }
    
    public var isFullscreen: Bool {
        guard let window = window else { return false }
        return window.styleMask.contains(.fullScreen)
    }
}

public class MacWindowControlsView: NSView {
    private var closeButton: NSButton?
    private var miniaturizeButton: NSButton?
    private var zoomButton: NSButton?
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        guard let window = self.window else { return }
        
        // Instantiate the 3 buttons
        closeButton = NSWindow.standardWindowButton(.closeButton, for: window.styleMask)
        miniaturizeButton = NSWindow.standardWindowButton(.miniaturizeButton, for: window.styleMask)
        zoomButton = NSWindow.standardWindowButton(.zoomButton, for: window.styleMask)
        
        if let closeButton = closeButton {
            addSubview(closeButton)
            closeButton.frame = CGRect(x: 7, y: 6, width: 14, height: 16)
        }
        
        if let miniaturizeButton = miniaturizeButton {
            addSubview(miniaturizeButton)
            miniaturizeButton.frame = CGRect(x: 27, y: 6, width: 14, height: 16)
        }
        
        if let zoomButton = zoomButton {
            addSubview(zoomButton)
            zoomButton.frame = CGRect(x: 47, y: 6, width: 14, height: 16)
        }
    }
    
    public override var intrinsicContentSize: NSSize {
        return NSSize(width: 68, height: 28)
    }
}

// SwiftUI wrapper for MacWindowControlsView
public struct MacWindowControls: NSViewRepresentable {
    public init() {}
    
    // TODO: Fix lack of hover effect
    
    public func makeNSView(context: Context) -> MacWindowControlsView {
        return MacWindowControlsView()
    }
    
    public func updateNSView(_ nsView: MacWindowControlsView, context: Context) {
        // No updates needed
    }
}

#endif

struct MacWindowControlsIfValidElse<V: View>: View {
    @Environment(\.isFullscreen) private var isFullscreen
    var leftPadding: CGFloat = 0
    @ViewBuilder var elseView: () -> V
    
    var body: some View {
        #if os(macOS)
        if !isFullscreen {
            MacWindowControls()
                .frame(width: 68, height: 28)
                .padding(.leading, leftPadding)
        } else {
            elseView()
        }
        #else
        elseView()
        #endif
    }
}
