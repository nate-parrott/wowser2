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
    case recipeContent(URL, Recipe)
    
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
        case .recipeContent(let url, _):
            return url
        }
    }
    
    var readerContent: ReadableDoc? {
        if case .readerContent(_, let extractedContent) = self {
            return extractedContent
        }
        return nil
    }
    
    var recipeContent: Recipe? {
        if case .recipeContent(_, let recipe) = self {
            return recipe
        }
        return nil
    }
}

extension WebContentWebKit {
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
        
        // if url has changed, reset state
        if docReadyWithURL.historyKey != fullContentExtractionStatus.url?.historyKey {
            fullContentExtractionStatus = .none
        }
        
        @MainActor
        func refreshNow() async {
            self.fullContentExtractionStatus = .inProgress(docReadyWithURL)
            let inProgressState = self.fullContentExtractionStatus
            // Refresh now
            do {
                switch extractionMode {
                case .reader:
                    let (contentURL, content) = try await refreshExtractedReaderModeNow()
                    // Ensure url hasn't changed in the meantime
                    if self.fullContentExtractionStatus == inProgressState, inProgressState.url?.historyKey == contentURL.historyKey {
                        self.fullContentExtractionStatus = .readerContent(contentURL, content)
                    }
//                case .recipe:
//                    if let (contentURL, recipe) = try await refreshExtractedRecipeNow(),
//                       self.fullContentExtractionStatus == inProgressState,
//                       inProgressState.url?.historyKey == contentURL.historyKey
//                    {
//                        self.fullContentExtractionStatus = .recipeContent(contentURL, recipe)
//                    } else {
//                        self.fullContentExtractionStatus = .nothingToExtract(docReadyWithURL)
//                    }
                }
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
        case .inProgress, .readerContent, .nothingToExtract, .recipeContent: () // we know url is unchanged, so do nothing
        }
    }

    private func refreshExtractedReaderModeNow() async throws -> (URL, ReadableDoc) {
        struct Output: Codable {
            var url: URL
            var html: String
        }
        do {
            if let (url, recipe) = try await tryToExtractRecipe(), let readableDoc = recipe.asReadableDoc {
                return (url, readableDoc)
            }
        } catch {
            print("[Recipe extraction error]: \(error)")
        }
        let output = try await webview.evaluateJS("({ url: location.href, html: document.documentElement.innerHTML })", resultType: Output.self)
        let extracted = try await Reeeed.extractReadableDoc(url: output.url, html: output.html)
        return (output.url, extracted)
    }
}
