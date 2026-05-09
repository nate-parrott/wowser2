import SwiftUI
import Foundation

/// View modifier that creates a drop target on the right edge of a view
/// for creating a split view when a tab is dropped.
///
/// The drop overlay is only hit-testable while `armed` is true. The window
/// arms it on mouseDown over the sidebar (just before a tab drag could
/// start) and disarms on mouseUp, so file drops to web pages aren't blocked
/// by a permanently-on overlay.
struct DropToCreateSplitViewTarget: ViewModifier {
    let paneId: ID<WebContent>?

    @State private var isTargeted = false
    @State private var armed = false

    @Environment(\.windowID) private var windowID

    func body(content: Content) -> some View {
        content
            .overlay {
                if armed || isTargeted {
                    Color.clear
                        .onDrop(of: ["public.text"], isTargeted: $isTargeted) { providers, _ in
                            let handled = providers.first?.loadObject(ofClass: String.self) { string, _ in
                                guard let string = string else { return }
                                handleDrop(tabIDString: string)
                            }
                            return handled != nil
                        }
                }
            }
            .overlay {
                if isTargeted {
                    HStack(spacing: 0) {
                        Color.clear
                        Color.accentColor.opacity(0.3)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTabDropTargets)) { _ in
                armed = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .hideTabDropTargets)) { _ in
                armed = false
                isTargeted = false
            }
//            .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }

    private func handleDrop(tabIDString: String) {
        let tabID = ID<Tab>(raw: tabIDString)
        guard let paneId, let destinationTab = BrowserStore.shared.model.tabContaining(paneId: paneId) else {
            return
        }


//        // Verify that the tab can be moved
//        guard let sourceTabId = BrowserStore.shared.model.tabContaining(paneId: tabID),
//              let destinationTabId = BrowserStore.shared.model.tabContaining(paneId: paneId),
//              sourceTabId != destinationTabId else {
//            return
//        }

        // Perform the move operation
        BrowserStore.shared.modify { state in
            // TODO: insert at proper index
            state.moveAllPanesToSplitView(sourceTabId: tabID, destinationTabId: destinationTab)
        }
    }
}

extension BrowserState {
    /// Helper method to find the tab containing a specific pane
    func tabContaining(paneId: ID<WebContent>) -> ID<Tab>? {
        for (tabId, tab) in tabs {
            if tab.panes.contains(where: { $0.id == paneId }) {
                return tabId
            }
        }
        return nil
    }
}

// Extension to make it easy to apply the modifier
extension View {
    /// Adds a drop target to the right edge of a view for creating split views
    /// - Parameters:
    ///   - paneId: The ID of the pane this view represents
    ///   - edgeWidth: Width of the drop target (default: 40)
    /// - Returns: A view with the drop target modifier applied
    func dropToCreateSplitViewTarget(paneId: ID<WebContent>?) -> some View {
        self.modifier(DropToCreateSplitViewTarget(paneId: paneId))
    }
}
