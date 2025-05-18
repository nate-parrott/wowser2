import SwiftUI

public struct MobileContentView: View {
    public var windowID: ID<WindowState>
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        Color.red
    }
}

private struct MobileContentSnapshot: Equatable {
    var currentPane: ID<WebContent>?
    var searchActive = false
    
    init(state: BrowserState, windowID: ID<WindowState>) {
        guard let window = state.windows[windowID] else {
            return
        }
        
        self.currentPane = state.currentPane(forWindow: windowID)
        searchActive = window.searchOverlayActive
    }
}
