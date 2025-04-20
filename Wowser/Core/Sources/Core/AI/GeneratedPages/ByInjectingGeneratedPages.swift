import Foundation
import SwiftUI
import Combine

struct ByInjectingGeneratedPages: ViewModifier {
    var webContent: WebContent
    
    func body(content: Content) -> some View {
        content
        // Setup triggering of page gen
            .background {
                WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.generatedPageKeyForCurrentURL(inWebContentId: webContent.id) }) { key in
                    Color.clear
                        .onAppearOrChange(of: key) { key in
                            if let key {
                                GeneratedPageStore.shared.ensureGeneratedPageLoaded(for: key)
                            }
                        }
                }
            }
        // Setup injection of cached html
            .onReceive(BrowserStore.shared.generatedPageContentForCurrentURL(inWebContentId: webContent.id)) { (value: GeneratedPageValue?) in
                if let value {
                    let js = """
                    if (location.href === \(value.key.url.encodedAsJSONString)) {
                        document.documentElement.innerHTML = \(value.html.encodedAsJSONString)
                    }
                    """
                    webContent.webview.evaluateJavaScript(js)
                }
            }
    }
}

private extension BrowserState {
    func generatedPageKeyForCurrentURL(inWebContentId id: ID<WebContent>?) -> GeneratedPageKey? {
        guard let id,
            let url = tabInfo(forWebContentId: id)?.url
        else { return nil }
        return GeneratedPageKey(url: url)
    }
}

private extension BrowserStore {
    func generatedPageContentForCurrentURL(inWebContentId id: ID<WebContent>?) -> AnyPublisher<GeneratedPageValue?, Never> {
        uiPublisher
            .map({ $0.generatedPageKeyForCurrentURL(inWebContentId: id) })
            .map { (key: GeneratedPageKey?) -> AnyPublisher<GeneratedPageValue?, Never> in
                if let key {
                    return GeneratedPageStore.shared.publisher.map({ $0.pages[key] }).eraseToAnyPublisher()
                }
                return Just(nil).eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

//
//public class GeneratedPageHandler: ObservableObject {
//    private var subscriptions = Set<AnyCancellable>()
//    private var webContentObservers = [NSKeyValueObservation]()
//    
//    @Published public var webContent: WebContent? {
//        didSet {
//            // Cancel old observers
//            webContentObservers.forEach { $0.invalidate() }
//            webContentObservers.removeAll()
//            
//            // Set up new observers
//            if let webContent = webContent {
//                setupWebContentObservation(webContent)
//            }
//        }
//    }
//    
//    public init(webContent: WebContent? = nil) {
//        self.webContent = webContent
//        
//        // Observe store updates to refresh content if needed
//        GeneratedPageStore.shared.uiPublisher
//            .sink { [weak self] _ in
//                guard let self = self, 
//                      let webContent = self.webContent,
//                      let url = webContent.webview.url,
//                      self.isGeneratedPage(url) else { return }
//                
//                self.updateGeneratedPageContent(for: url)
//            }
//            .store(in: &subscriptions)
//        
//        // Set up observation if webContent is already set
//        if let webContent = webContent {
//            setupWebContentObservation(webContent)
//        }
//    }
//    
//    private func setupWebContentObservation(_ webContent: WebContent) {
//        // Observe URL changes
//        let urlObserver = webContent.webview.observe(\.url, options: [.new]) { [weak self] _, change in
//            if let url = change.newValue ?? nil, let self = self {
//                self.handlePotentialGeneratedPageURL(url)
//            }
//        }
//        webContentObservers.append(urlObserver)
//        
//        // Check if current URL is a generated page
//        if let url = webContent.webview.url, isGeneratedPage(url) {
//            handlePotentialGeneratedPageURL(url)
//        }
//    }
//    
//    // Check if URL is a generated page
//    public func isGeneratedPage(_ url: URL) -> Bool {
//        return GeneratedPageKey(url: url) != nil
//    }
//    
//    // Handle URL changes that might be generated pages
//    private func handlePotentialGeneratedPageURL(_ url: URL) {
//        guard let pageKey = GeneratedPageKey(url: url) else { return }
//        
//        // Ensure we have a generated page for this key
//        GeneratedPageStore.shared.ensureGeneratedPageLoaded(for: pageKey)
//        
//        // Update content immediately if we already have it
//        updateGeneratedPageContent(for: url)
//    }
//    
//    // Update the webview content with generated page content
//    private func updateGeneratedPageContent(for url: URL) {
//        guard let pageKey = GeneratedPageKey(url: url),
//              let generatedPage = GeneratedPageStore.shared.model.pages[pageKey],
//              let webContent = self.webContent else {
//            return
//        }
//        
//        // Simple JS to replace the page content
//        let js = """
//        (function() {
//            document.open();
//            document.write(`\(generatedPage.html.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`);
//            document.close();
//        })();
//        """
//        
//        webContent.webview.evaluateJavaScript(js) { result, error in
//            if let error = error {
//                print("Error updating generated page content: \(error)")
//            }
//        }
//    }
//}
