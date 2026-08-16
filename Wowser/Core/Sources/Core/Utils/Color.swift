import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
extension NSColor {
    func withAlphaComponentSafe(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { _ in
            self.withAlphaComponent(alpha)
        }
    }
}
#endif

public extension Color {
    /// Dynamic color that resolves to `darkMode` in dark appearance and `light` otherwise.
    init(darkMode: Color, light: Color) {
        #if os(macOS)
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(darkMode) : NSColor(light)
        })
        #else
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(darkMode) : UIColor(light)
        })
        #endif
    }
}

public struct HSBA: Equatable, Codable {
    public var hue: CGFloat
    public var saturation: CGFloat
    public var brightness: CGFloat
    public var alpha: CGFloat

    public var uiColor: UINSColor {
        .init(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    public var color: Color {
        Color(uiColor)
    }

    var hsla: HSLA {
        // from https://gist.github.com/adamgraham/3ada1f7f4cdf8131dd3d2d95bd116cfc
        var hsla = HSLA(hue: hue, saturation: 0, lightness: 0, alpha: alpha)
        hsla.lightness = ((2.0 - saturation) * brightness) / 2.0

        switch hsla.lightness {
        case 0.0, 1.0:
            hsla.saturation = 0.0
        case 0.0..<0.5:
            hsla.saturation = (saturation * brightness) / (hsla.lightness * 2.0)
        default:
            hsla.saturation = (saturation * brightness) / (2.0 - hsla.lightness * 2.0)
        }
        return hsla
    }

    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        let r = brightness * (1 - saturation * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1)))
        let g = brightness * (1 - saturation)
        let b = brightness * (1 - saturation * (1 - abs((hue * 6 + 2).truncatingRemainder(dividingBy: 2) - 1)))
        return (r, g, b, alpha)
    }
}

struct HSLA: Equatable, Codable {
    // from https://gist.github.com/adamgraham/3ada1f7f4cdf8131dd3d2d95bd116cfc
    var hue: CGFloat
    var saturation: CGFloat
    var lightness: CGFloat
    var alpha: CGFloat

    var hsba: HSBA {
        var hsba = HSBA(hue: hue, saturation: 0, brightness: 0, alpha: alpha)
        let t = saturation * ((lightness < 0.5) ? lightness : (1.0 - lightness))
        hsba.brightness = lightness + t
        hsba.saturation = (lightness > 0.0) ? (2.0 * t / hsba.brightness) : 0.0
        return hsba
    }

    var uiColor: UINSColor {
        hsba.uiColor
    }

    var color: Color {
        Color(uiColor)
    }
}

extension UINSColor {
    var hsba: HSBA {
        var s = HSBA(hue: 0, saturation: 0, brightness: 1, alpha: 1)
        getHue(&s.hue, saturation: &s.saturation, brightness: &s.brightness, alpha: &s.alpha)
        return s
    }
}

//enum ImageDominantColor {
//    private static let dominantColorQueue = DispatchQueue(label: "DominantColorQueue", qos: .background)
//
//    enum DominantColorError: Error {
//        case failedToDecodeImage
//    }
//
//    static func getDominantColors(imageData: Data, maxSize: CGFloat) async throws -> [HSBA] {
//        try await withCheckedThrowingContinuation { cont in
//            Self.dominantColorQueue.async {
//                do {
//                    guard let image = UINSImage(data: imageData) else {
//                        throw DominantColorError.failedToDecodeImage
//                    }
//                    let resized = image.resized(toMaximumDimension: maxSize)
//                    let colors = try resized.dominantColors()
//                    cont.resume(returning: colors.map(\.hsba))
//                } catch {
//                    cont.resume(throwing: error)
//                }
//            }
//        }
//    }
//}
