#if os(macOS)
import SwiftUI
import AppKit

/// A toolbar-styled button that, on click, builds an `NSMenu` and pops it up
/// at the button's position via `NSMenu.popUp(positioning:at:in:)`. Looks like
/// a `ToolbarButtonStyle` button so it can sit alongside the others without
/// the SwiftUI `Menu` chrome.
struct ToolbarPopUpButton: View {
    var symbolName: String
    var help: String
    var buildMenu: () -> NSMenu

    @State private var anchorView = FlippedAnchorView()

    var body: some View {
        Button(action: present) {
            Image(systemName: symbolName)
                .imageScale(.medium)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(help)
        .background(MenuAnchor(view: anchorView))
    }

    private func present() {
        let menu = buildMenu()
        guard menu.items.count > 0 else { return }
        let bounds = anchorView.bounds
        let point = NSPoint(x: bounds.minX, y: bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: anchorView)
    }
}

private struct MenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
}
#endif
