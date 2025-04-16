import SwiftUI

/// A view that displays a favicon for a given URL
public struct FaviconView: View {
    /// The URL to display the favicon for
    let url: URL?
    
    /// The favicon URL (if explicitly provided)
    let faviconURL: URL?
    
    /// The size of the favicon (width and height)
    let size: CGFloat
    
    /// Creates a new favicon view
    /// - Parameters:
    ///   - url: The URL to display the favicon for
    ///   - faviconURL: The explicit favicon URL (if available)
    ///   - size: The size of the favicon (defaults to 16)
    public init(url: URL?, faviconURL: URL? = nil, size: CGFloat = 16) {
        self.url = url
        self.faviconURL = faviconURL
        self.size = size
    }
    
    /// The favicon URL to use for display
    private var displayFaviconURL: URL? {
        // First try using the explicit favicon URL if provided
        if let faviconURL = faviconURL {
            return faviconURL
        }
        
        // Fall back to Google favicon service
        guard let url = url, let host = url.host else { return nil }
        let urlString = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        return URL(string: urlString)
    }
    
    public var body: some View {
        Group {
            if let displayURL = displayFaviconURL {
                AsyncImage(url: displayURL) { phase in
                    switch phase {
                    case .empty:
                        placeholderCircle
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        placeholderCircle
                    @unknown default:
                        placeholderCircle
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            } else {
                placeholderCircle
            }
        }
        .frame(width: size, height: size)
    }
    
    /// A placeholder circle in the site's primary color
    private var placeholderCircle: some View {
        Circle()
            .fill(.primary)
            .opacity(0.1)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            FaviconView(url: URL(string: "https://www.apple.com"))
                .frame(width: 16, height: 16)
            
            Text("Apple")
        }
        
        HStack(spacing: 16) {
            FaviconView(url: URL(string: "https://www.google.com"), size: 24)
            
            Text("Google")
        }
        
        HStack(spacing: 16) {
            FaviconView(url: URL(string: "https://www.github.com"), size: 32)
            
            Text("GitHub")
        }
        
        HStack(spacing: 16) {
            FaviconView(url: nil, size: 20)
            
            Text("No URL")
        }
    }
    .padding()
}
