import SwiftUI
import Foundation

// View modifier for handling tab drag and drop
struct SidebarDropTarget: ViewModifier {
    typealias DropDestinationProvider = (CGPoint, CGSize) -> TabDropDestination?
    
    let dropDestinationForPoint: DropDestinationProvider
    @State private var isTargeted = false
    @State private var size: CGSize = .zero
    
    func body(content: Content) -> some View {
        content
            .measureSize({ self.size = $0 })
            .onDrop(of: ["public.text"], isTargeted: $isTargeted) { providers, point in
                let dragTabIDString = providers.first?.loadObject(ofClass: String.self) { string, _ in
                    guard let string = string else { return }
                    handleDrop(tabIDString: string, at: point)
                }
                
                return dragTabIDString != nil
            }
            .opacity(isTargeted ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }
    
    private func handleDrop(tabIDString: String, at point: CGPoint) {
        let tabID = ID<Tab>(raw: tabIDString)
        guard let dest = dropDestinationForPoint(point, size) else { return }
        
        // Verify that we can move the tab to this destination
        guard BrowserStore.shared.model.canMove(tab: tabID, to: dest) else { return }
        
        // Perform the move operation
        BrowserStore.shared.modify { state in
            state.move(tab: tabID, to: dest, makeActiveInWindow: nil)
        }
    }
}

// Extension to make it easy to apply the modifier
extension View {
    func sidebarDropTarget(dropDestinationForPoint: @escaping SidebarDropTarget.DropDestinationProvider) -> some View {
        self.modifier(SidebarDropTarget(dropDestinationForPoint: dropDestinationForPoint))
    }
}
