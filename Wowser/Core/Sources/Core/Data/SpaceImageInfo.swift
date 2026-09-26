import Foundation
import CoreGraphics
import ImageIO

/// A user-dropped background image for a space, plus the visual identity
/// derived from it at ingest time: a tint color (dominant image color,
/// adjusted so white text stays legible on it) and whether the space's UI
/// should render dark or light over the image.
public struct SpaceImageInfo: Equatable, Codable {
    /// File name inside `SpaceImageInfo.storageDirectory`.
    public var fileName: String
    /// Dominant image color, pre-adjusted for visibility as a UI tint.
    public var tint: HSBA
    /// True when the image is dark overall → the space's UI renders dark.
    public var prefersDarkUI: Bool
    /// Raw dominant image color (not tint-adjusted); `fade` mode overlays it.
    /// Optional so images ingested before it existed still decode; falls back to `tint`.
    public var dominantColor: HSBA?
    /// How the image is rendered behind the window. Optional for old persisted state.
    public var mode: SpaceBackgroundMode?

    public var effectiveMode: SpaceBackgroundMode { mode ?? .fade }
    public var effectiveDominantColor: HSBA { dominantColor ?? tint }
}

/// Per-space rendering treatment for the background image
/// ("Background Image Mode" in the sidebar context menu).
public enum SpaceBackgroundMode: String, Codable, CaseIterable, Equatable {
    case asIs   // aspect-fill, untouched
    case blur   // soft gaussian blur, rendered once and cached
    case fade   // aspect-fill with the dominant color laid over it at 75%

    public var title: String {
        switch self {
        case .asIs: return "As Is"
        case .blur: return "Blur"
        case .fade: return "Fade"
        }
    }
}

public extension SpaceImageInfo {
    /// Directory holding space background image files. Path is computed once;
    /// `ingest` creates it on demand before writing.
    static let storageDirectory: URL = {
        let appDir = "WowserDataStores-\(isProd() ? "prod" : "dev")"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appDir)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Unknown")
            .appendingPathComponent("SpaceBackgrounds")
    }()

    var fileURL: URL { Self.storageDirectory.appendingPathComponent(fileName) }
}

extension SpaceImageInfo {
    /// Writes `imageData` into app storage and analyzes a thumbnail for the
    /// dominant color + overall luminance. Decodes the image; call off the
    /// main thread.
    static func ingest(imageData: Data) -> SpaceImageInfo? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let analysis = ImageAnalysis(source: source) else { return nil }

        let ext: String
        switch CGImageSourceGetType(source) as String? {
        case "public.png": ext = "png"
        case "public.jpeg": ext = "jpg"
        case "public.heic", "public.heif": ext = "heic"
        case "com.compuserve.gif": ext = "gif"
        case "public.tiff": ext = "tiff"
        case "org.webmproject.webp": ext = "webp"
        default: ext = "img"
        }

        let fileName = UUID().uuidString + "." + ext
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try imageData.write(to: storageDirectory.appendingPathComponent(fileName))
        } catch {
            print("[SpaceBG] Failed to write background image: \(error)")
            return nil
        }

        return SpaceImageInfo(
            fileName: fileName,
            tint: analysis.visibleTint,
            prefersDarkUI: analysis.meanLuminance < 0.45,
            dominantColor: HSBA(hue: analysis.dominant.hue, saturation: analysis.dominant.saturation,
                                brightness: analysis.dominant.brightness, alpha: 1),
            mode: .fade
        )
    }
}

/// Small-thumbnail color analysis: dominant color via a coarse HSB histogram
/// (weighted toward saturated pixels so a colorful accent wins over large
/// gray expanses) and mean relative luminance for the dark/light decision.
private struct ImageAnalysis {
    var dominant: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)
    var meanLuminance: CGFloat

    init?(source: CGImageSource) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = thumb.width, height = thumb.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Histogram over quantized HSB bins.
        struct Bin { var weight: CGFloat = 0; var h: CGFloat = 0; var s: CGFloat = 0; var b: CGFloat = 0; var count: CGFloat = 0 }
        var bins = [Int: Bin]()
        var luminanceSum: CGFloat = 0
        let pixelCount = width * height

        for i in 0..<pixelCount {
            let r = CGFloat(pixels[i * 4]) / 255
            let g = CGFloat(pixels[i * 4 + 1]) / 255
            let b = CGFloat(pixels[i * 4 + 2]) / 255
            luminanceSum += 0.2126 * r + 0.7152 * g + 0.0722 * b

            let (h, s, v) = Self.rgbToHSB(r: r, g: g, b: b)
            // Saturated midtones make good tints; near-gray or near-black
            // pixels get a small residual weight so gray images still resolve.
            let weight = 0.05 + s * min(1, v * 1.4)
            let key = Int(h * 11.99) * 100 + Int(s * 2.99) * 10 + Int(v * 2.99)
            var bin = bins[key] ?? Bin()
            bin.weight += weight
            bin.h += h; bin.s += s; bin.b += v; bin.count += 1
            bins[key] = bin
        }

        guard let best = bins.values.max(by: { $0.weight < $1.weight }), best.count > 0 else { return nil }
        dominant = (best.h / best.count, best.s / best.count, best.b / best.count)
        meanLuminance = luminanceSum / CGFloat(pixelCount)
    }

    /// The dominant color pushed into a range that works as a UI tint: enough
    /// chroma to read as a color, brightness walked down (same guardrail as
    /// `SpaceTheme.tintColor`) until white text on it clears ~3:1 contrast.
    var visibleTint: HSBA {
        let hue = dominant.hue
        let saturation = min(max(dominant.saturation, 0.4), 0.85)
        var brightness = max(dominant.brightness, 0.55)
        while brightness > 0.35,
              SpaceTheme.relativeLuminance(hue: hue * 360, saturation: saturation, brightness: brightness) > 0.26 {
            brightness -= 0.02
        }
        return HSBA(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func rgbToHSB(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        var h: CGFloat = 0
        if delta > 0 {
            if maxV == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxV == 0 ? 0 : delta / maxV
        return (h, s, maxV)
    }
}

public extension BrowserStore {
    /// Handles an image dropped on a space's sidebar: writes it to app
    /// storage, derives tint + UI scheme, and sets it as the space background.
    func setSpaceBackgroundImage(data: Data, profileID: ID<Profile>) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard var info = SpaceImageInfo.ingest(imageData: data) else {
                print("[SpaceBG] Could not decode dropped image")
                return
            }
            let oldInfo = self.model.profiles[profileID]?.imageInfo
            let oldFileURL = oldInfo?.fileURL
            // Swapping the image keeps the space's chosen rendering mode.
            info.mode = oldInfo?.effectiveMode ?? info.mode
            self.modify { state in
                state.profiles[profileID]?.imageInfo = info
            }
            if let oldFileURL {
                try? FileManager.default.removeItem(at: oldFileURL)
            }
        }
    }

    func setSpaceBackgroundMode(_ mode: SpaceBackgroundMode, profileID: ID<Profile>) {
        modify { state in
            state.profiles[profileID]?.imageInfo?.mode = mode
        }
    }

    func clearSpaceBackgroundImage(profileID: ID<Profile>) {
        let oldFileURL = model.profiles[profileID]?.imageInfo?.fileURL
        modify { state in
            state.profiles[profileID]?.imageInfo = nil
        }
        if let oldFileURL {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: oldFileURL)
            }
        }
    }
}
