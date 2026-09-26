import SwiftUI
import CoreImage
import Combine

// MARK: - Cache

/// Renders a space background image for a given mode off the main thread and
/// caches the result per (file, mode) so window resizes and re-renders never
/// re-run CoreImage. Blur is baked into the bitmap (no visual effect views).
final class SpaceBackgroundImageCache {
    static let shared = SpaceBackgroundImageCache()

    struct Key: Hashable {
        var fileURL: URL
        var mode: SpaceBackgroundMode
    }

    private var images = [Key: CGImage]()
    private var inflight = [Key: [(CGImage?) -> Void]]()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "SpaceBackgroundImageCache", qos: .userInitiated)
    // Software renderer on purpose: this runs once per (space, mode) on a
    // background queue, and creating a Metal-backed CIContext concurrently
    // with other Metal context creation (e.g. the DominantColors package's
    // per-call CIContext on the page color queue) crashes inside Metal's
    // binary archive loading under the GPU debug layer.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    /// Kicks off rendering for `keys` that aren't cached yet, so a later
    /// `image(for:)` for them completes synchronously (e.g. swiping between
    /// spaces swaps the backdrop in the same frame as the tint/scheme).
    func prewarm(_ keys: Set<Key>) {
        for key in keys { image(for: key) { _ in } }
    }

    /// `completion` runs on the main thread — synchronously if already cached.
    func image(for key: Key, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            completion(cached)
            return
        }
        if inflight[key] != nil {
            inflight[key]!.append(completion)
            lock.unlock()
            return
        }
        inflight[key] = [completion]
        lock.unlock()

        queue.async { [self] in
            let result = Self.render(key)
            lock.lock()
            if let result { images[key] = result }
            let waiters = inflight.removeValue(forKey: key) ?? []
            lock.unlock()
            DispatchQueue.main.async { waiters.forEach { $0(result) } }
        }
    }

    private static func render(_ key: Key) -> CGImage? {
        guard let source = CIImage(contentsOf: key.fileURL) else {
            print("[SpaceBG] Could not load image at \(key.fileURL.path)")
            return nil
        }
        var img = source.transformed(by: .init(translationX: -source.extent.minX, y: -source.extent.minY))

        // Cap the rendered size: 2048px is plenty for a window backdrop, and
        // blur mode works on a smaller bitmap since fine detail is gone anyway.
        let maxDim: CGFloat = key.mode == .blur ? 1024 : 2048
        let scale = min(1, maxDim / max(img.extent.width, img.extent.height))
        if scale < 1 {
            img = img.transformed(by: .init(scaleX: scale, y: scale))
        }
        let rect = CGRect(origin: .zero, size: CGSize(width: floor(img.extent.width), height: floor(img.extent.height)))

        if key.mode == .blur {
            img = img
                .clampedToExtent()
                // Radius is in bitmap pixels (≤1024px wide), so ~2% of the
                // width: enough to soften detail without turning it to soup.
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 20])
                .cropped(to: rect)
        } else {
            img = img.cropped(to: rect)
        }
        return ciContext.createCGImage(img, from: rect)
    }
}

// MARK: - Prewarming

/// Keeps every visible space's background rendered and cached, so switching
/// spaces never waits on a CoreImage decode. Attach once per window.
struct SpaceBackgroundPrewarmer: ViewModifier {
    func body(content: Content) -> some View {
        content.onReceive(
            BrowserStore.shared.uiPublisher
                .map { state in
                    Set(state.visibleProfiles.compactMap { profile -> SpaceBackgroundImageCache.Key? in
                        guard let info = profile.imageInfo else { return nil }
                        return .init(fileURL: info.fileURL, mode: info.effectiveMode)
                    })
                }
                .removeDuplicates()
        ) { keys in
            SpaceBackgroundImageCache.shared.prewarm(keys)
        }
    }
}

// MARK: - View

/// Fills the window with the space's background image, treated per the
/// space's `SpaceBackgroundMode`.
struct SpaceBackgroundView: View {
    var info: SpaceImageInfo

    @State private var image: CGImage?
    /// Key the displayed/in-flight `image` belongs to. Tracked in @State rather
    /// than compared against `self.key`, because the deprecated
    /// `onChange(of:perform:)` closure captures the *old* self.
    @State private var loadedKey: SpaceBackgroundImageCache.Key?

    private var key: SpaceBackgroundImageCache.Key {
        .init(fileURL: info.fileURL, mode: info.effectiveMode)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if info.effectiveMode == .fade {
                    info.effectiveDominantColor.color.opacity(0.75)
                }
            }
        }
        .clipped()
        .onAppearOrChange(of: key) { key in
            if loadedKey != key {
                loadedKey = key
                image = nil
            }
            SpaceBackgroundImageCache.shared.image(for: key) { result in
                // Ignore late results for a key we've since moved past.
                guard key == loadedKey else { return }
                image = result
            }
        }
    }
}
