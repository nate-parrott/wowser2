import SwiftUI

#if os(macOS)
import AppKit
#endif

extension View {
    /// Tracks mouse position globally (even outside window bounds) on macOS.
    /// On iOS, this is a no-op and the callback is never called.
    ///
    /// - Parameter onMouseMoved: Callback with mouse position relative to view and view bounds
    /// - Returns: Modified view with mouse tracking capability
    func trackMouseOutsideWindow(onMouseMoved: @escaping (CGPoint, CGRect) -> Void) -> some View {
        #if os(macOS)
        return self.background(MouseTrackerRepresentable(onMouseMoved: onMouseMoved))
        #else
        // No-op on non-macOS platforms
        return self
        #endif
    }
}

#if os(macOS)
// Private implementation for macOS only
private struct MouseTrackerRepresentable: NSViewRepresentable {
    let onMouseMoved: (CGPoint, CGRect) -> Void
    
    func makeNSView(context: Context) -> MouseTrackerView {
        let view = MouseTrackerView()
        view.onMouseMoved = onMouseMoved
        return view
    }
    
    func updateNSView(_ nsView: MouseTrackerView, context: Context) {
        nsView.onMouseMoved = onMouseMoved
    }
    
    // Custom NSView that sets up the global event monitor
    class MouseTrackerView: NSView {
        var onMouseMoved: ((CGPoint, CGRect) -> Void)?
        var mouseMonitor: Any?
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            
            // Set up the monitor when the view is added to a window
            if window != nil && mouseMonitor == nil {
                setupMouseMonitor()
            } else if window == nil && mouseMonitor != nil {
                removeMouseMonitor()
            }
        }
        
        override func removeFromSuperview() {
            removeMouseMonitor()
            super.removeFromSuperview()
        }
        
        deinit {
            removeMouseMonitor()
        }
        
        private func setupMouseMonitor() {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self = self else { return event }
                
                // Get the global mouse position
                let globalPosition = NSEvent.mouseLocation
                
                // Convert to a position relative to this view if needed
                if let window = self.window {
                    let windowPosition = window.convertPoint(fromScreen: globalPosition)
                    let viewPosition = self.convert(windowPosition, from: nil)
                    
                    // Convert to flipped coordinates (y=0 at top)
                    let flippedY = self.bounds.height - viewPosition.y
                    let flippedPosition = CGPoint(x: viewPosition.x, y: flippedY)
                    
                    // Call the callback with position and bounds
                    self.onMouseMoved?(flippedPosition, self.bounds)
                }
                return event
            }
        }
        
        private func removeMouseMonitor() {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
        }
    }
}
#endif
