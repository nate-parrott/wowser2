import SwiftUI

#if os(macOS)
import AppKit

/// A view that renders a behind-window blur effect on macOS
public struct TransparentBg: View {
    public init() {}
    
    public var body: some View {
        VisualEffectView()
            .edgesIgnoringSafeArea(.all)
    }
}

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // No updates needed
    }
}
#else
import UIKit

/// A transparent background view - on iOS this is just a plain view
public struct TransparentBg: View {
    public init() {}
    
    public var body: some View {
        // Just a plain view for iOS
        Color.clear
    }
}
#endif