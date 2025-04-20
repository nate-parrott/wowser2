import Foundation
import ChatToys

// Generator for AI-powered pages
public enum PageGenerator {
    // Generation functions
    public static func generateContent(for key: GeneratedPageKey) -> AsyncThrowingStream<ContentUpdate, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    switch key {
                    case .homepage:
                        try await generateHomepage(continuation: continuation)
                    case .answer(let query):
                        try await generateAnswer(query: query, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private static func generateHomepage(continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        // Initial loading page
        continuation.yield(ContentUpdate(
            html: """
            <html>
            <head>
                <title>AI Home</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
                    h1 { color: #0066cc; }
                    @media (prefers-color-scheme: dark) {
                        body { background-color: #1a1a1a; color: #e0e0e0; }
                        h1 { color: #6ab0ff; }
                    }
                </style>
            </head>
            <body>
                <h1>Welcome to AI Home</h1>
                <p>Loading your personalized homepage...</p>
            </body>
            </html>
            """,
            progress: 0.2,
            stage: "Creating page structure"
        ))
        
        // Final content
        continuation.yield(ContentUpdate(
            html: """
            <html>
            <head>
                <title>AI Home</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
                    h1 { color: #0066cc; }
                    .search-box { padding: 10px; width: 100%; font-size: 16px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; margin-bottom: 20px; }
                    .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin-bottom: 20px; transition: all 0.3s ease; background-color: white; }
                    .card:hover { box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
                    .card h2 { margin-top: 0; }
                    a { color: #0066cc; text-decoration: none; }
                    a:hover { text-decoration: underline; }
                    .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
                    @media (prefers-color-scheme: dark) {
                        body { background-color: #1a1a1a; color: #e0e0e0; }
                        .card { background-color: #2a2a2a; border-color: #444; color: #e0e0e0; }
                        a { color: #6ab0ff; }
                        h1 { color: #6ab0ff; }
                        .search-box { background-color: #2a2a2a; color: #e0e0e0; border-color: #444; }
                    }
                </style>
                <script>
                    function performSearch() {
                        const query = document.getElementById('searchInput').value.trim();
                        if (query) {
                            window.location.href = 'about:blank#answer=' + encodeURIComponent(query);
                        }
                    }
                </script>
            </head>
            <body>
                <h1>Welcome to AI Home</h1>
                <div style="display: flex;">
                    <input type="text" id="searchInput" class="search-box" placeholder="Ask me anything..." 
                           onkeydown="if(event.key==='Enter') performSearch()">
                    <button onclick="performSearch()" style="margin-left: 10px; padding: 10px 20px; background-color: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer;">Ask</button>
                </div>
                
                <h2>Quick Actions</h2>
                <div class="cards">
                </div>
            </body>
            </html>
            """,
            progress: 1.0,
            stage: "Completed"
        ))
    }
    
//    private static func getPersonalizedSuggestions() async throws -> String {
//        // Get the current LLM model
//        let llm = try LLMs.currentOrThrow(json: false)
//        
//        // Build the prompt for personalized suggestions
//        let prompt = """
//        Create 3-4 card suggestions for an AI assistant homepage. Each card should represent a different type of task the AI can help with. Format each card as HTML with this structure:
//        
//        <div class="card">
//            <h2>[CATEGORY NAME]</h2>
//            <p>[Brief description of what this category helps with]</p>
//            <a href="about:blank#answer=[EXAMPLE QUERY]">[Text for link]</a>
//        </div>
//        
//        Focus on diverse and helpful suggestions that would appeal to a broad audience. Make sure the example queries are clear and specific.
//        """
//        
//        // Call the LLM with the prompt
//        let response = try await llm.completeChat([.init(role: .user, content: prompt)])
//        
//        // Return the response text as HTML content
//        return response.choices.first?.message.content ?? ""
//    }
    
    private static func generateAnswer(query: String, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        // Initial loading page
        continuation.yield(ContentUpdate(
            html: """
            <html>
            <head>
                <title>Answer: \(query)</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
                    h1 { color: #0066cc; }
                    .query { background-color: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
                    .answer { min-height: 300px; }
                    @media (prefers-color-scheme: dark) {
                        body { background-color: #1a1a1a; color: #e0e0e0; }
                        .query { background-color: #2a2a2a; color: #e0e0e0; }
                        h1 { color: #6ab0ff; }
                    }
                </style>
            </head>
            <body>
                <h1>Answer</h1>
                <div class="query">
                    <strong>Question:</strong> \(query)
                </div>
                <div class="answer">
                    <p>Thinking...</p>
                </div>
            </body>
            </html>
            """,
            progress: 0.1,
            stage: "Processing query"
        ))
        
        // Get answer from LLM
        let answer = "Sample answer" // try await callLLM(query: query)
        
        // Final content with answer
        continuation.yield(ContentUpdate(
            html: """
            <html>
            <head>
                <title>Answer: \(query)</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
                    h1 { color: #0066cc; }
                    .query { background-color: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
                    .answer { min-height: 300px; }
                    .back { margin-top: 30px; }
                    .back a { color: #0066cc; text-decoration: none; }
                    .back a:hover { text-decoration: underline; }
                    @media (prefers-color-scheme: dark) {
                        body { background-color: #1a1a1a; color: #e0e0e0; }
                        .query { background-color: #2a2a2a; color: #e0e0e0; }
                        .back a { color: #6ab0ff; }
                        h1 { color: #6ab0ff; }
                    }
                </style>
            </head>
            <body>
                <h1>Answer</h1>
                <div class="query">
                    <strong>Question:</strong> \(query)
                </div>
                <div class="answer">
                    \(answer)
                </div>
                <div class="back">
                    <a href="about:blank#home=1">← Back to Home</a>
                </div>
            </body>
            </html>
            """,
            progress: 1.0,
            stage: "Completed"
        ))
    }
}

