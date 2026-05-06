import SwiftUI
import WebKit

/// A reusable view for the find-in-page UI.
/// `paneID` participates in the FocusTarget system (`.findInPage`) when set.
/// When nil (e.g. the reader overlay's local find bar, which has its own
/// internal webview unrelated to the pane), focus is handled locally on
/// appear.
struct FindInPageView: View {
    var webView: WKWebView
    var paneID: ID<WebContent>?
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var hasMatch = false
    @State private var matchCount = 0
    @State private var focusSnap = FocusSnap()
    @State private var localFocusDate: Date?
    @Environment(\.windowID) private var windowID

    private var focusDate: Date? {
        if let paneID {
            return focusSnap.target == .findInPage(paneID) ? focusSnap.date : nil
        }
        return localFocusDate
    }

    private var focusTarget: FocusTarget? {
        paneID.map { FocusTarget.findInPage($0) }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 12) {
            // Search input
            InputTextField(
                text: $searchText,
                options: InputTextFieldOptions(
                    placeholder: "Find in page",
                    font: UINSFont.systemFont(ofSize: 15),
                    insets: CGSize(width: 5, height: 5)
                ),
                focusDate: focusDate,
                focusTarget: focusTarget,
                onEvent: { event in
                   handle(event)
                }
            )
            .frame(height: 30)
            .onChange(of: searchText) { _ in
                performSearch()
            }
            .onReceiveFocusSnap(windowID: windowID) { self.focusSnap = $0 }
            .onAppear { if paneID == nil { localFocusDate = Date() } }
            
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
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.1), Color.black.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    .background(.thinMaterial)
                    .clipShape(shape)
                    .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
                
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
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
