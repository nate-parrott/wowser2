import AppKit

public class ArchiveMenuItem: NSMenuItem {
    private var callback: (() -> Void)?
    private let archiveItem: ArchiveItem
    private var loadTask: Task<Void, Never>?
    
    init(archiveItem: ArchiveItem, callback: @escaping () -> Void) {
        self.archiveItem = archiveItem
        self.callback = callback
        
        // Initialize with the title
        let displayTitle = archiveItem.tidyTitle ?? archiveItem.title ?? archiveItem.url.absoluteString
        super.init(title: displayTitle, action: #selector(performCallback), keyEquivalent: "")
        self.image = .menuFaviconPlaceholder
        
        self.target = self
        
        // Load the favicon asynchronously
        loadTask = Task { 
            await loadFaviconAsync()
        }
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        loadTask?.cancel()
    }
    
    private func loadFaviconAsync() async {
        do {
            if let faviconImage = try await archiveItem.url.loadFavicon(size: CGSize(width: 14, height: 14), cornerRadius: 3) {
                await MainActor.run {
                    self.image = faviconImage
                }
            }
        } catch {
            // Keep placeholder on error
        }
    }
    
    @objc private func performCallback() {
        callback?()
    }
}

// MARK: - Favicon Loading Extensions

private extension URL {
    func loadFavicon(size: CGSize, cornerRadius: CGFloat) async throws -> NSImage? {
        guard let host = self.host else { return nil }
        let urlString = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        guard let faviconURL = URL(string: urlString) else { return nil }
        
        let imageData = try await faviconURL.fetchImageData()
        guard let image = NSImage(data: imageData) else { return nil }
        
        return image.processForMenu(size: size, cornerRadius: cornerRadius)
    }
    
    func fetchImageData() async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: self)
        return data
    }
}

private extension NSImage {
    func processForMenu(size: CGSize, cornerRadius: CGFloat) -> NSImage {
        let resultImage = NSImage(size: size)
        
        resultImage.lockFocus()
        
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        
        // Draw resized image
        self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        
        resultImage.unlockFocus()
        return resultImage
    }
}

extension NSImage {
    static var menuFaviconPlaceholder: NSImage = {
        return NSImage(named: "MenuPlaceholderIcon")!
    }()
}
