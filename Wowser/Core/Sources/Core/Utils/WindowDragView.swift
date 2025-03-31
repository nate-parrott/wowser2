#if os(macOS)
import SwiftUI
import AppKit

struct WindowDragView: NSViewRepresentable {
    var onTapped: (() -> Void)?
    
    func makeNSView(context: Context) -> NSView {
        let view = DraggableView()
        view.wantsLayer = true
        view.onTapped = onTapped
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let draggableView = nsView as? DraggableView {
            draggableView.onTapped = onTapped
        }
    }
    
    class DraggableView: NSView {
        var onTapped: (() -> Void)?
        private var mouseDownLocation: NSPoint?
        
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.wantsLayer = true
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.wantsLayer = true
        }
        
        override var mouseDownCanMoveWindow: Bool {
            return true
        }
        
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            // Store the initial location in screen coordinates
            mouseDownLocation = NSEvent.mouseLocation
        }
        
        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            
            if let downLocation = mouseDownLocation {
                let upLocation = NSEvent.mouseLocation
                
                // Calculate distance between down and up locations
                let dx = upLocation.x - downLocation.x
                let dy = upLocation.y - downLocation.y
                let distance = sqrt(dx*dx + dy*dy)
                
                // If distance is less than 3px, consider it a tap
                if distance < 3.0 {
                    onTapped?()
                }
            }
            
            // Reset the stored location
            mouseDownLocation = nil
        }
    }
}
#endif
