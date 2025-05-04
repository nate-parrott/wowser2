import Foundation
import WebKit
import Reeeed

enum FullContentExtractionMode: Equatable {
    case reader
}

enum FullContentExtractionStatus: Equatable, Codable {
    case none
    case inProgress(URL)
    case nothingToExtract(URL)
    case readerContent(URL, ReadableDoc)
    
    var url: URL? {
        switch self {
        case .none:
            return nil
        case .inProgress(let uRL):
            return uRL
        case .nothingToExtract(let uRL):
            return uRL
        case .readerContent(let url, _):
            return url
        }
    }
    
    var readerContent: ReadableDoc? {
        if case .readerContent(_, let extractedContent) = self {
            return extractedContent
        }
        return nil
    }
}

extension WebContent {
    // docReadyWithURL: is document.readyState interactive or complete? if so, what url did we report?
    @MainActor
    func updateFullContentExtractionIfNecessary(docReadyWithURL: URL?) async throws {
        guard let docReadyWithURL, let extractionMode = fullContentExtractionMode else {
            // if url is missing or extraction is off, reset state
            if self.fullContentExtractionStatus != .none {
                self.fullContentExtractionStatus = .none
            }
            return
        }
        
        switch extractionMode {
        case .reader: () // no op right now; case is present to make sure we handle if we add more modes
        }
        
        // if url has changed, reset state
        if docReadyWithURL.historyKey != fullContentExtractionStatus.url?.historyKey {
            fullContentExtractionStatus = .none
        }
        
        @MainActor
        func refreshNow() async {
            self.fullContentExtractionStatus = .inProgress(docReadyWithURL)
            // Refresh now
            do {
                let (contentURL, content) = try await refreshExtractedReaderModeNow()
                if self.fullContentExtractionStatus.url?.historyKey != contentURL.historyKey {
                    return
                }
                self.fullContentExtractionStatus = .readerContent(contentURL, content)
            } catch {
                // TODO: dont log; this is normal
                print("Unable to extract content: \(error)")
                if self.fullContentExtractionStatus.url?.historyKey != docReadyWithURL.historyKey {
                    return
                }
                self.fullContentExtractionStatus = .nothingToExtract(docReadyWithURL)
            }
        }
        
        switch fullContentExtractionStatus {
        case .none: await refreshNow()
        case .inProgress, .readerContent, .nothingToExtract: () // we know url is unchanged, so do nothing
        }
    }

    private func refreshExtractedReaderModeNow() async throws -> (URL, ReadableDoc) {
        struct Output: Codable {
            var url: URL
            var html: String
        }
        let output = try await webview.evaluateJS("({ url: location.href, html: document.documentElement.innerHTML })", resultType: Output.self)
        let extracted = try await Reeeed.extractReadableDoc(url: output.url, html: output.html)
        return (output.url, extracted)
    }
}
