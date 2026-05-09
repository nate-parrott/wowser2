#if os(macOS)
import SwiftUI
import AppKit

/// Tiny helper that exposes the host `NSWindow` to SwiftUI. Add via
/// `.background(WindowAccessor { window in ... })`.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            onWindow(v?.window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onWindow(nsView?.window)
        }
    }
}
#endif
