import Foundation
import Combine

//
//public struct GeneratedPageValue: Equatable, Codable {
//    var key: GeneratedPageKey
//    var html: String
//    var loadProgress: Double? // nil if done
//    var expiration: Date
//    var lastAccessed: Date
//    var loadingTask: String? // Used for displaying the current stage of generation
//    
//    public static func == (lhs: GeneratedPageValue, rhs: GeneratedPageValue) -> Bool {
//        lhs.key == rhs.key &&
//        lhs.html == rhs.html &&
//        lhs.loadProgress == rhs.loadProgress &&
//        lhs.expiration == rhs.expiration &&
//        lhs.lastAccessed == rhs.lastAccessed &&
//        lhs.loadingTask == rhs.loadingTask
//    }
//}
//
//public class GeneratedPageStore: DataStore<[GeneratedPageKey: GeneratedPageValue]> {
//    public static let shared = GeneratedPageStore()
//    
//    override init() {
//        super.init(defaultValue: [:], key: "GeneratedPages")
//    }
//    
//    // Ensure a generated page exists
//    public func ensureGeneratedPageLoaded(for key: GeneratedPageKey) {
//        Task {
//            await modifyAsync { pages in
//                // If page doesn't exist or has expired, generate it
//                if pages[key] == nil || pages[key]?.expiration.timeIntervalSinceNow ?? 0 < 0 {
//                    // Create placeholder while we generate
//                    let now = Date()
//                    let expiration = now.addingTimeInterval(30 * 60) // 30 minute expiration
//                    
//                    // Set initial state with loading indicator
//                    pages[key] = GeneratedPageValue(
//                        key: key,
//                        html: "<html><body><h1>Loading...</h1></body></html>",
//                        loadProgress: 0.0,
//                        expiration: expiration,
//                        lastAccessed: now,
//                        loadingTask: "Starting generation"
//                    )
//                    
//                    // Start generation in background
//                    self.startGenerationTask(for: key)
//                } else {
//                    // Update last accessed time
//                    pages[key]?.lastAccessed = Date()
//                }
//            }
//        }
//    }
//    
//    private func startGenerationTask(for key: GeneratedPageKey) {
//        Task {
//            do {
//                // Get the content stream for this key
//                let contentStream = generateContent(for: key)
//                
//                // Process the stream of updates
//                for try await update in contentStream {
//                    await self.updateGeneratedPage(for: key, with: update)
//                }
//                
//                // Mark as completed
//                await modifyAsync { pages in
//                    pages[key]?.loadProgress = nil
//                    pages[key]?.loadingTask = nil
//                }
//            } catch {
//                print("Error generating content for \(key): \(error)")
//                await modifyAsync { pages in
//                    if var page = pages[key] {
//                        page.html = "<html><body><h1>Error generating content</h1><p>\(error.localizedDescription)</p></body></html>"
//                        page.loadProgress = nil
//                        page.loadingTask = "Error: \(error.localizedDescription)"
//                        pages[key] = page
//                    }
//                }
//            }
//        }
//    }
//    
//    private func updateGeneratedPage(for key: GeneratedPageKey, with update: ContentUpdate) async {
//        await modifyAsync { pages in
//            guard var page = pages[key] else { return }
//            
//            page.html = update.html
//            page.loadProgress = update.progress < 1.0 ? update.progress : nil
//            page.loadingTask = update.stage
//            pages[key] = page
//        }
//    }
//}
//
//// Content update structure
//struct ContentUpdate {
//    let html: String
//    let progress: Double
//    let stage: String?
//}
//
//// Generation functions
//func generateContent(for key: GeneratedPageKey) -> AsyncThrowingStream<ContentUpdate, Error> {
//    return AsyncThrowingStream { continuation in
//        Task {
//            do {
//                switch key {
//                case .homepage:
//                    try await generateHomepage(continuation: continuation)
//                case .answer(let query):
//                    try await generateAnswer(query: query, continuation: continuation)
//                }
//                continuation.finish()
//            } catch {
//                continuation.finish(throwing: error)
//            }
//        }
//    }
//}
//
//private func generateHomepage(continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
//    // Send initial content
//    continuation.yield(ContentUpdate(
//        html: """
//        <html>
//        <head>
//            <title>AI Home</title>
//            <style>
//                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
//                h1 { color: #0066cc; }
//                .search-box { padding: 10px; width: 100%; font-size: 16px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; margin-bottom: 20px; }
//                .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin-bottom: 20px; transition: all 0.3s ease; }
//                .card:hover { box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
//                .card h2 { margin-top: 0; }
//                .loading { text-align: center; padding: 40px; }
//            </style>
//        </head>
//        <body>
//            <h1>Welcome to AI Home</h1>
//            <p>Loading your personalized homepage...</p>
//        </body>
//        </html>
//        """,
//        progress: 0.2,
//        stage: "Creating page structure"
//    ))
//    
//    // Simulate content generation steps
//    await Task.sleep(seconds: 0.5)
//    
//    continuation.yield(ContentUpdate(
//        html: """
//        <html>
//        <head>
//            <title>AI Home</title>
//            <style>
//                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
//                h1 { color: #0066cc; }
//                .search-box { padding: 10px; width: 100%; font-size: 16px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; margin-bottom: 20px; }
//                .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin-bottom: 20px; transition: all 0.3s ease; }
//                .card:hover { box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
//                .card h2 { margin-top: 0; }
//                .loading { text-align: center; padding: 40px; }
//                a { color: #0066cc; text-decoration: none; }
//                a:hover { text-decoration: underline; }
//                .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
//            </style>
//        </head>
//        <body>
//            <h1>Welcome to AI Home</h1>
//            <input type="text" class="search-box" placeholder="Ask me anything..." onkeydown="if(event.key==='Enter') window.location.href='about:blank#answer='+encodeURIComponent(this.value)">
//            
//            <h2>Quick Actions</h2>
//            <div class="cards">
//                <div class="card">
//                    <h2>Get Summaries</h2>
//                    <p>Ask for quick summaries of articles, concepts, or topics.</p>
//                    <a href="about:blank#answer=summarize the current webpage">Summarize webpage</a>
//                </div>
//                <div class="card">
//                    <h2>Answer Questions</h2>
//                    <p>Get answers to your questions about any topic.</p>
//                    <a href="about:blank#answer=what is quantum computing">Example: What is quantum computing?</a>
//                </div>
//            </div>
//        </body>
//        </html>
//        """,
//        progress: 0.8,
//        stage: "Adding interactive elements"
//    ))
//    
//    await Task.sleep(seconds: 0.5)
//    
//    // Final content
//    continuation.yield(ContentUpdate(
//        html: """
//        <html>
//        <head>
//            <title>AI Home</title>
//            <style>
//                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
//                h1 { color: #0066cc; }
//                .search-box { padding: 10px; width: 100%; font-size: 16px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; margin-bottom: 20px; }
//                .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin-bottom: 20px; transition: all 0.3s ease; background-color: white; }
//                .card:hover { box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
//                .card h2 { margin-top: 0; }
//                a { color: #0066cc; text-decoration: none; }
//                a:hover { text-decoration: underline; }
//                .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
//                @media (prefers-color-scheme: dark) {
//                    body { background-color: #1a1a1a; color: #e0e0e0; }
//                    .card { background-color: #2a2a2a; border-color: #444; color: #e0e0e0; }
//                    a { color: #6ab0ff; }
//                    h1 { color: #6ab0ff; }
//                    .search-box { background-color: #2a2a2a; color: #e0e0e0; border-color: #444; }
//                }
//            </style>
//            <script>
//                function performSearch() {
//                    const query = document.getElementById('searchInput').value.trim();
//                    if (query) {
//                        window.location.href = 'about:blank#answer=' + encodeURIComponent(query);
//                    }
//                }
//            </script>
//        </head>
//        <body>
//            <h1>Welcome to AI Home</h1>
//            <div style="display: flex;">
//                <input type="text" id="searchInput" class="search-box" placeholder="Ask me anything..." 
//                       onkeydown="if(event.key==='Enter') performSearch()">
//                <button onclick="performSearch()" style="margin-left: 10px; padding: 10px 20px; background-color: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer;">Ask</button>
//            </div>
//            
//            <h2>Quick Actions</h2>
//            <div class="cards">
//                <div class="card">
//                    <h2>Get Summaries</h2>
//                    <p>Ask for quick summaries of articles, concepts, or topics.</p>
//                    <a href="about:blank#answer=summarize the current webpage">Summarize webpage</a>
//                </div>
//                <div class="card">
//                    <h2>Answer Questions</h2>
//                    <p>Get answers to your questions about any topic.</p>
//                    <a href="about:blank#answer=what is quantum computing">Example: What is quantum computing?</a>
//                </div>
//                <div class="card">
//                    <h2>Draft Content</h2>
//                    <p>Get help drafting emails, messages, or creative content.</p>
//                    <a href="about:blank#answer=write an email declining a meeting invitation politely">Draft an email</a>
//                </div>
//            </div>
//        </body>
//        </html>
//        """,
//        progress: 1.0,
//        stage: "Completed"
//    ))
//}
//
//private func generateAnswer(query: String, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
//    // Send initial content
//    continuation.yield(ContentUpdate(
//        html: """
//        <html>
//        <head>
//            <title>Answer: \(query)</title>
//            <style>
//                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
//                h1 { color: #0066cc; }
//                .query { background-color: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
//                .answer { min-height: 300px; }
//                .loading { display: flex; justify-content: center; align-items: center; height: 50px; }
//                .dot { height: 12px; width: 12px; background-color: #0066cc; border-radius: 50%; margin: 0 6px; animation: pulse 1.5s infinite ease-in-out; }
//                .dot:nth-child(2) { animation-delay: 0.3s; }
//                .dot:nth-child(3) { animation-delay: 0.6s; }
//                @keyframes pulse { 0%, 100% { transform: scale(0.8); opacity: 0.6; } 50% { transform: scale(1.2); opacity: 1; } }
//                @media (prefers-color-scheme: dark) {
//                    body { background-color: #1a1a1a; color: #e0e0e0; }
//                    .query { background-color: #2a2a2a; color: #e0e0e0; }
//                }
//            </style>
//        </head>
//        <body>
//            <h1>Answer</h1>
//            <div class="query">
//                <strong>Question:</strong> \(query)
//            </div>
//            <div class="answer">
//                <div class="loading">
//                    <div class="dot"></div>
//                    <div class="dot"></div>
//                    <div class="dot"></div>
//                </div>
//                <p>Generating answer...</p>
//            </div>
//        </body>
//        </html>
//        """,
//        progress: 0.1,
//        stage: "Processing query"
//    ))
//    
//    // Simulate thinking time
//    await Task.sleep(seconds: 1.0)
//    
//    // Generate a simple response based on the query
//    // In a real implementation, this would connect to an LLM API
//    let generatedAnswer = generateSimpleAnswer(for: query)
//    
//    continuation.yield(ContentUpdate(
//        html: """
//        <html>
//        <head>
//            <title>Answer: \(query)</title>
//            <style>
//                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
//                h1 { color: #0066cc; }
//                .query { background-color: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
//                .answer { min-height: 300px; }
//                .back { margin-top: 30px; }
//                .back a { color: #0066cc; text-decoration: none; }
//                .back a:hover { text-decoration: underline; }
//                @media (prefers-color-scheme: dark) {
//                    body { background-color: #1a1a1a; color: #e0e0e0; }
//                    .query { background-color: #2a2a2a; color: #e0e0e0; }
//                    .back a { color: #6ab0ff; }
//                }
//            </style>
//        </head>
//        <body>
//            <h1>Answer</h1>
//            <div class="query">
//                <strong>Question:</strong> \(query)
//            </div>
//            <div class="answer">
//                \(generatedAnswer)
//            </div>
//            <div class="back">
//                <a href="about:blank#home=1">← Back to Home</a>
//            </div>
//        </body>
//        </html>
//        """,
//        progress: 1.0,
//        stage: "Completed"
//    ))
//}
//
//private func generateSimpleAnswer(for query: String) -> String {
//    // In a real implementation, this would call an LLM API
//    // This is just a simple placeholder implementation
//    
//    let lowerQuery = query.lowercased()
//    
//    if lowerQuery.contains("hello") || lowerQuery.contains("hi") {
//        return "<p>Hello! How can I assist you today?</p>"
//    } else if lowerQuery.contains("weather") {
//        return "<p>I don't have access to real-time weather data, but you can check a weather service for the most up-to-date information.</p>"
//    } else if lowerQuery.contains("time") {
//        let formatter = DateFormatter()
//        formatter.dateStyle = .none
//        formatter.timeStyle = .medium
//        return "<p>The current time is \(formatter.string(from: Date())). Note that this is based on your device's time.</p>"
//    } else if lowerQuery.contains("quantum computing") {
//        return """
//        <p>Quantum computing is a type of computing that uses quantum-mechanical phenomena, such as superposition and entanglement, to perform operations on data.</p>
//        
//        <p>Unlike classical computers that use bits (0 or 1), quantum computers use quantum bits or qubits, which can exist in multiple states simultaneously thanks to superposition. This potentially allows quantum computers to solve certain problems much faster than classical computers.</p>
//        
//        <p>Some key applications of quantum computing include:</p>
//        <ul>
//            <li>Cryptography and security</li>
//            <li>Drug discovery and materials science</li>
//            <li>Optimization problems</li>
//            <li>Machine learning</li>
//            <li>Financial modeling</li>
//        </ul>
//        
//        <p>While quantum computing shows great promise, it's still in relatively early stages of development, with practical quantum computers having limited qubits and facing challenges with error rates and qubit stability.</p>
//        """
//    } else if lowerQuery.contains("summarize") {
//        return "<p>To summarize a webpage, I would need access to its content. In a full implementation, this feature would extract the main text from the current page and generate a concise summary highlighting the key points.</p>"
//    } else {
//        return "<p>I'm a simple placeholder response. In a full implementation, this would connect to an LLM API to generate a more helpful and accurate answer to your question: \"" + query + "\".</p>"
//    }
//}
//
//extension Task where Success == Never, Failure == Never {
//    static func sleep(seconds: Double) async throws {
//        let duration = UInt64(seconds * 1_000_000_000)
//        try await Task.sleep(nanoseconds: duration)
//    }
//}
