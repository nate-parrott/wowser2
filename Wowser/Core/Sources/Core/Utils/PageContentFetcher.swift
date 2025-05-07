import ChatToys
import WebKit
import SwiftUI

@MainActor
class PageContentFetcher {
    private let url: URL
    private var webView: WKWebView?
    private let profileID: ID<Profile>?
    private let visual: Bool // includes page content as image, in addition to text
    
    init(url: URL, profileID: ID<Profile>?, visual: Bool) {
        self.url = url
        self.profileID = profileID
        self.visual = visual
    }
    
    private func ensureWebview() async -> WKWebView {
        if let webView {
            return webView
        }
        if let profileID, let prof = await BrowserStore.shared.readAsync().profiles[profileID] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .init(forIdentifier: prof.dataStoreUUID)
            self.webView = WKWebView(frame: .zero, configuration: config)
            return self.webView!
        }
        self.webView = WKWebView(frame: .zero)
        return self.webView!
    }
    
    func fetch() async throws -> AsyncThrowingStream<ContextItem.PageContent, Error> {
        let webView = await ensureWebview()
        // Load the URL
        let request = URLRequest(url: url)
        webView.load(request)
        
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                // Poll content every second for 5s or until complete
                var stepWhenLastStillLoading = 0
                let maxSteps = 20
                for step in 0...maxSteps {
                    // Check if navigation is complete
                    if webView.isLoading {
                        stepWhenLastStillLoading = step
                    }
                    
                    let complete = step > stepWhenLastStillLoading + 2 || step == 20
                    
                    // Get page text
                    if let text = try? await webView.markdown() {
                        let truncated = String(text.prefix(30_000))
//                        if complete {
//                            print("FETCHED: \(truncated)")
//                        }
                        if visual {
                            let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration()).asLLMImage(detail: .auto, maxSize: 1024)
                            continuation.yield(ContextItem.PageContent(text: truncated, image: image, loadComplete: complete))
                        } else {
                            continuation.yield(ContextItem.PageContent(text: truncated, loadComplete: complete))
                        }
                    }
                    
                    if complete {
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                
                continuation.finish()
            }
        }

    }
}
