import WebKit
import Foundation
import SwiftUI
import Combine

@MainActor
public class ThumbnailCache {
    private let cache = NSCache<NSString, UINSImage>()
    private var subscriptions = Set<AnyCancellable>()
    
    public static let shared = ThumbnailCache()
    @Published private(set) var cacheUpdateCount = 0
    
    private init() {
        // Configure cache limits
        cache.countLimit = 10
        
        // Observe BrowserStore
        BrowserStore.shared.uiPublisher
            .map { state -> [ID<WindowState>: ID<Tab>] in
                var result = [ID<WindowState>: ID<Tab>]()
                for (windowId, window) in state.windows {
                    if let currentTab = window.currentTab {
                        result[windowId] = currentTab
                    }
                }
                return result
            }
            .sink { [weak self] windowTabMap in
                self?.lastTabByWindow = windowTabMap
            }
            .store(in: &subscriptions)
    }
    
    private var lastTabByWindow = [ID<WindowState>: ID<Tab>]() {
        didSet {
            // Detect tab changes
            for (windowId, newTabId) in lastTabByWindow {
                let oldTabId = oldValue[windowId]
                
                // If tab changed and there was a previous tab, capture screenshots of all its panes
                if oldTabId != nil && oldTabId != newTabId {
                    captureAllPaneThumbnails(tabId: oldTabId!)
                }
            }
        }
    }
    
    private func captureAllPaneThumbnails(tabId: ID<Tab>) {
        guard let tab = BrowserStore.shared.model.tabs[tabId] else { return }

        // Take screenshots of all panes in the tab
        for pane in tab.panes {
            let paneId = pane.id

            // Only thumbnail panes that are already loaded — an unloaded pane has
            // nothing on screen to capture, and forcing one to load here would
            // instantiate a WKWebView that never gets reclaimed.
            guard let webContent = BrowserStore.shared.existingWebContent(forId: paneId) else { continue }

            // Native pages (terminal, file browser, vscode, chat) don't get
            // thumbnails; FakePaneContent draws a kind-specific placeholder instead.
            if webContent.info.url.flatMap(NativePageKey.init(url:)) != nil { continue }

            Task {
                // High-performance screenshot configuration
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = false // Don't wait for screen updates for better performance
                
                // Capture screenshot
                do {
                    guard let wkWebview = webContent.wkWebview else { return }
                    let screenshot = try await wkWebview.takeSnapshot(configuration: config)
                    // Store in cache
                    DispatchQueue.main.async {
                        self.cache.setObject(screenshot, forKey: paneId.raw as NSString)
                        self.cacheUpdateCount += 1
                    }
                } catch {
                    print("Error capturing tab thumbnail: \(error)")
                }
            }
        }
    }
    
    public func getThumbnail(for contentId: ID<WebContent>) -> UINSImage? {
        return cache.object(forKey: contentId.raw as NSString)
    }
    
    public func clearCache() {
        cache.removeAllObjects()
    }
}

/// A SwiftUI view that provides a thumbnail image for a web content ID
public struct WithThumbnail<V: View>: View {
    private let contentId: ID<WebContent>
    private let render: (UINSImage?) -> V
    
    @State private var thumbnail: UINSImage? = nil
    @State private var cacheUpdateCounter: Int = 0
    
    /// Creates a view that will display the cached thumbnail for a WebContent
    /// - Parameters:
    ///   - id: The WebContent ID to get a thumbnail for
    ///   - render: A view builder closure that receives the thumbnail image (or nil if none cached)
    public init(id: ID<WebContent>, @ViewBuilder render: @escaping (UINSImage?) -> V) {
        self.contentId = id
        self.render = render
    }
    
    public var body: some View {
        render(thumbnail)
            .onAppear {
                loadThumbnail()
            }
            .onReceive(ThumbnailCache.shared.$cacheUpdateCount) { count in
                // Check cache again whenever the cacheUpdateCount changes
                if count != cacheUpdateCounter {
                    cacheUpdateCounter = count
                    loadThumbnail()
                }
            }
    }
    
    private func loadThumbnail() {
        Task { @MainActor in
            thumbnail = ThumbnailCache.shared.getThumbnail(for: contentId)
        }
    }
}

// Example usage:
// WithThumbnail(id: webContentId) { image in
//     if let image = image {
//         Image(nsImage: image)
//             .resizable()
//             .aspectRatio(contentMode: .fill)
//     } else {
//         Color.gray // Placeholder when no thumbnail is available
//     }
// }
