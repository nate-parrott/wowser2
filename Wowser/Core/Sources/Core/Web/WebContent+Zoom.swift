import Foundation
import WebKit

// MARK: - Zoom Extension
extension WebContent {
    // Zoom constants
    private static let zoomIncrement: CGFloat = 0.1
    private static let defaultZoom: CGFloat = 1.0
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 3.0
    
    /// Increases the zoom level of the web content
    public func zoomIn() {
        #if os(macOS)
        let currentMagnification = webview.magnification
        let newMagnification = min(currentMagnification + WebContent.zoomIncrement, WebContent.maxZoom)
        webview.magnification = newMagnification
        #endif
    }
    
    /// Decreases the zoom level of the web content
    public func zoomOut() {
        #if os(macOS)
        let currentMagnification = webview.magnification
        let newMagnification = max(currentMagnification - WebContent.zoomIncrement, WebContent.minZoom)
        webview.magnification = newMagnification
        #endif
    }
    
    /// Resets the zoom level to the default value
    public func resetZoom() {
        #if os(macOS)
        webview.magnification = WebContent.defaultZoom
        #endif
    }
}