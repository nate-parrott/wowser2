import SwiftUI
import WebKit

/// A reusable view for the find-in-page UI
struct FindInPageView: View {
    var webView: WKWebView
    var onClose: () -> Void
    
    @State private var searchText = ""
    @State private var hasMatch = false
    @State private var matchCount = 0
    @State private var focusDate: Date?
    
    var body: some View {
        HStack(spacing: 12) {
            // Search input
            InputTextField(
                text: $searchText,
                options: InputTextFieldOptions(
                    placeholder: "Find in page",
                    font: NSFont.systemFont(ofSize: 15),
                    insets: CGSize(width: 5, height: 5)
                ),
                focusDate: focusDate,
                onEvent: { event in
                   handle(event)
                }
            )
            .frame(height: 30)
            .onChange(of: searchText) { _ in
                performSearch()
            }
            .onAppear { self.focusDate = Date() }
            
            // Match indicator
            if !hasMatch && searchText != "" {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            // Navigation buttons
            HStack(spacing: 6) {
                Button(action: findPrevious) {
                    Image(systemName: "chevron.up")
                        .help("Previous Match")
                        .frame(both: 28)
                }
                .disabled(!hasMatch)
                
                Button(action: findNext) {
                    Image(systemName: "chevron.down")
                        .help("Next Match")
                        .frame(both: 28)
                }
                .disabled(!hasMatch)
            }
            
            // Close button
            Button(action: {
                clearFind()
                onClose()
            }) {
                Image(systemName: "xmark")
                    .help("Close")
                    .frame(both: 28)
            }
        }
        .buttonStyle(GhostButtonStyle())
        .frame(maxWidth: 300)
        .padding(8)
        .background {
            Color.white.opacity(0.01)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
        }
    }
    
    private func handle(_ event: TextFieldEvent) {
        if case .key(.enter) = event {
            findNext()
        } else if case .key(.escape) = event {
            onClose()
        }
    }
    
    private func performSearch() {
        guard !searchText.isEmpty else {
            clearFind()
            return
        }
        
        let configuration = WKFindConfiguration()
        webView.find(searchText, configuration: configuration) { result in
            DispatchQueue.main.async {
                self.hasMatch = result.matchFound
//                self.matchCount = result.matchFound ? result.matchCount : 0
            }
        }
    }
    
    private func findNext() {
        guard !searchText.isEmpty && hasMatch else { return }
        
        let config = WKFindConfiguration()
        config.backwards = false
        webView.find(searchText, configuration: config) { _ in
            // No additional action needed
        }
    }
    
    private func findPrevious() {
        guard !searchText.isEmpty && hasMatch else { return }
        
        let config = WKFindConfiguration()
        config.backwards = true
        webView.find(searchText, configuration: config) { _ in
            // No additional action needed
        }
    }
    
    private func clearFind() {
        // Clear the search by searching for empty string
        webView.find("", configuration: WKFindConfiguration()) { _ in
            // No additional action needed
        }
        searchText = ""
        hasMatch = false
        matchCount = 0
    }
}
