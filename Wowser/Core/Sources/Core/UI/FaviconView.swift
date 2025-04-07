import SwiftUI

/// A view that displays a favicon for a given URL
public struct FaviconView: View {
    /// The URL to display the favicon for
    let url: URL?
    
    /// The size of the favicon (width and height)
    let size: CGFloat
    
    /// Creates a new favicon view
    /// - Parameters:
    ///   - url: The URL to display the favicon for
    ///   - size: The size of the favicon (defaults to 16)
    public init(url: URL?, size: CGFloat = 16) {
        self.url = url
        self.size = size
    }
    
    /// The Google favicon service URL
    private var faviconURL: URL? {
        guard let url = url, let host = url.host else { return nil }
        let urlString = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        return URL(string: urlString)
    }
    
    public var body: some View {
        Group {
            if let faviconURL = faviconURL {
                AsyncImage(url: faviconURL) { phase in
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
    
//    /// Generates a consistent color based on the URL's host
//    private var primaryColor: Color {
//        guard let url = url, let host = url.host else {
//            return .blue // Default color for no URL
//        }
//        
//        // Use the domain name to generate a consistent color
//        let hash = abs(host.hashValue)
//        let hue = Double(hash % 256) / 255.0
//        
//        return Color(hue: hue, saturation: 0.8, brightness: 0.9)
//    }
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
