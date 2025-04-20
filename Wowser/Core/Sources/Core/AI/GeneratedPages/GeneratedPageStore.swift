import Foundation
import Combine

// Content update structure for page generation
public struct ContentUpdate {
    var html: String
    var progress: Double
    var stage: String?
}

public struct GeneratedPageValue: Equatable, Codable {
    var key: GeneratedPageKey
    var html: String
    var loadProgress: Double? // nil if done
    var expiration: Date
    var lastAccessed: Date
    var loadingTask: String? // Used for displaying the current stage of generation
}

public struct GeneratedPageState: Equatable, Codable {
    var pages: [GeneratedPageKey: GeneratedPageValue]
}

public class GeneratedPageStore: DataStore<GeneratedPageState> {
    public static let shared = GeneratedPageStore()
    
    init() {
        // Initialize on background thread
        super.init(persistenceKey: nil, defaultModel: .init(pages: [:]), queue: Queue.genericUserInitiated)
    }
    
    public override func cleanup(model: inout GeneratedPageState) {
        super.cleanup(model: &model)
        // TODO: Clean old pages
    }
    
    // Ensure a generated page exists
    public func ensureGeneratedPageLoaded(for key: GeneratedPageKey) {
        modify { state in
            // If page doesn't exist or has expired, generate it
            if state.pages[key] == nil || state.pages[key]?.expiration.timeIntervalSinceNow ?? 0 < 0 {
                // Create placeholder while we generate
                let now = Date()
                let expiration = now.addingTimeInterval(14 * 60 * 60) // 14 hour expiration
                
                // Set initial state with loading indicator
                state.pages[key] = GeneratedPageValue(
                    key: key,
                    html: "", // "<html><head><title>Loading...</title></head><body><h1>Loading...</h1></body></html>",
                    loadProgress: 0.0,
                    expiration: expiration,
                    lastAccessed: now,
                    loadingTask: "Loading..."
                )
                
                self.queue.queue.async {
                    // Start generation in background
                    self.startGenerationTask(for: key)
                }
            } else {
                // Update last accessed time
                state.pages[key]?.lastAccessed = Date()
            }
        }
    }
    
    private func startGenerationTask(for key: GeneratedPageKey) {
        Task {
            do {
                // Get the content stream for this key
                let contentStream = PageGenerator.generateContent(for: key)
                
                // Process the stream of updates
                for try await update in contentStream {
                    await self.updateGeneratedPage(for: key, with: update)
                }
                
                // Mark as completed
                await modifyAsync { state in
                    state.pages[key]?.loadProgress = nil
                    state.pages[key]?.loadingTask = nil
                }
            } catch {
                print("Error generating content for \(key): \(error)")
                await modifyAsync { state in
                    if var page = state.pages[key] {
                        page.html = "<html><head><title>Error</title></head><body><h1>Error generating content</h1><p>\(error.localizedDescription)</p></body></html>"
                        page.loadProgress = nil
                        page.loadingTask = "Error: \(error.localizedDescription)"
                        state.pages[key] = page
                    }
                }
            }
        }
    }
    
    private func updateGeneratedPage(for key: GeneratedPageKey, with update: ContentUpdate) async {
        await modifyAsync { state in
            guard var page = state.pages[key] else { return }
            
            page.html = update.html
            page.loadProgress = update.progress < 1.0 ? update.progress : nil
            page.loadingTask = update.stage
            state.pages[key] = page
        }
    }
}
