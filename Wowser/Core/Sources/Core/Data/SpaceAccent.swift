import SwiftUI

/// A window's accent color plus the "on-accent" color for text and icons
/// drawn on top of it (selected command-bar row).
///
/// Derived from a base color (space theme hue, or a background image's
/// dominant color): keep its hue and roughly its tone, then push it toward the
/// UI's foreground (lighter in dark UI, darker in light UI) until it stands
/// out from the backdrop it actually sits on. Over a faded background image
/// that backdrop is mostly the image's own dominant color — the same color the
/// accent comes from — so this push is what separates them. Saturation never
/// drops below `minSaturation`, so tinted glass stays visibly tinted.
/// The on-accent color (text and accent-colored icons on a selected
/// command-bar row) is whichever of a tinted near-white / near-black reads
/// best on the solid accent. Selected tabs don't need it: their liquid glass
/// handles legibility. Both colors resolve per light/dark appearance.
public struct SpaceAccent {
    public var accent: Color
    public var onAccent: Color

    /// Opacity of the accent tint on the selected tab's liquid glass.
    static let selectedTabTintOpacity = 0.5

    /// `hue`, `saturation`, `brightness` all 0–1. `backdropTint` is a color
    /// laid over the plain window background (e.g. a faded image's dominant
    /// color) with its opacity.
    init(hue: Double, saturation: Double, brightness: Double, backdropTint: (color: RGB, opacity: Double)? = nil) {
        // A near-gray source has no meaningful hue to keep; borrow one.
        let hue = saturation < 0.12 ? Self.fallbackHue : hue
        func backdrop(darkUI: Bool) -> RGB {
            let window = RGB.windowBackground(darkUI: darkUI)
            guard let backdropTint else { return window }
            return window.mixed(with: backdropTint.color, amount: backdropTint.opacity)
        }
        let light = Self.variant(hue: hue, saturation: saturation, brightness: brightness, darkUI: false, backdrop: backdrop(darkUI: false))
        let dark = Self.variant(hue: hue, saturation: saturation, brightness: brightness, darkUI: true, backdrop: backdrop(darkUI: true))
        accent = Color(darkMode: dark.accent, light: light.accent)
        onAccent = Color(darkMode: dark.onAccent, light: light.onAccent)
    }

    /// Image color wins over the theme hue; nil when the space has neither.
    static func forSpace(theme: SpaceTheme?, imageInfo: SpaceImageInfo?) -> SpaceAccent? {
        if let imageInfo {
            let c = imageInfo.effectiveDominantColor
            // Fade mode lays the dominant color over the image at 75%; the
            // other modes show the image itself, whose average leans the same
            // way, so approximate them with the same backdrop.
            let tint = RGB(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
            return SpaceAccent(hue: c.hue, saturation: c.saturation, brightness: c.brightness, backdropTint: (tint, 0.75))
        }
        if let theme {
            return SpaceAccent(hue: theme.hue / 360, saturation: 0.65, brightness: 0.78)
        }
        return nil
    }

    /// Built from the system accent color, for spaces with no theme or image.
    static var system: SpaceAccent {
        #if os(macOS)
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return SpaceAccent(hue: c.hueComponent, saturation: c.saturationComponent, brightness: c.brightnessComponent)
        #else
        return SpaceAccent(hue: 214.0 / 360, saturation: 0.65, brightness: 0.78)
        #endif
    }

    // MARK: - Derivation

    /// Minimum accent-vs-backdrop contrast (WCAG's bar for UI shapes).
    private static let minBackdropContrast = 3.0

    /// Saturation floor: below this the selected tab's tinted glass is hard
    /// to tell from untinted glass.
    private static let minSaturation = 0.35

    /// Hue for gray sources (gray image, graphite system accent): the system
    /// accent's when it has one, else blue.
    private static var fallbackHue: Double {
        #if os(macOS)
        if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB), c.saturationComponent >= 0.12 {
            return c.hueComponent
        }
        #endif
        return 214.0 / 360
    }

    /// Starting luminance window per scheme, before the backdrop mix. Mid-tones
    /// on purpose: a recognizable version of the base color.
    private static func accentLuminanceRange(darkUI: Bool) -> ClosedRange<Double> {
        darkUI ? 0.13...0.24 : 0.2...0.3
    }

    private static func variant(hue: Double, saturation: Double, brightness: Double, darkUI: Bool, backdrop: RGB) -> (accent: Color, onAccent: Color) {
        let hueDegrees = hue * 360
        let range = accentLuminanceRange(darkUI: darkUI)
        // Gray sources borrow a hue (see `init`), so every accent keeps enough
        // chroma to read as a color.
        var s = min(max(saturation, minSaturation), 0.9)
        var b = brightness
        func luminance() -> Double {
            SpaceTheme.relativeLuminance(hue: hueDegrees, saturation: s, brightness: b)
        }
        // Walk brightness toward the range; if brightness tops out (e.g. deep
        // blue in dark UI), shed saturation instead, down to the floor.
        for _ in 0..<150 {
            let l = luminance()
            if l < range.lowerBound {
                if b < 1 { b = min(1, b + 0.02) } else if s > minSaturation { s = max(minSaturation, s - 0.02) } else { break }
            } else if l > range.upperBound {
                if b > 0 { b = max(0, b - 0.02) } else { break }
            } else {
                break
            }
        }

        // Infuse with the foreground color until the accent separates from
        // what's behind it: brighten then whiten (dark UI) or darken (light
        // UI), never below the saturation floor. A tint that keeps its hue
        // beats one that clears the contrast bar by turning gray.
        let backdropL = backdrop.luminance
        for _ in 0..<150 where contrast(luminance(), backdropL) < minBackdropContrast {
            if darkUI {
                if b < 1 { b = min(1, b + 0.02) } else if s > minSaturation { s = max(minSaturation, s - 0.02) } else { break }
            } else {
                if b > 0.1 { b = max(0.1, b - 0.02) } else { break }
            }
        }
        let accent = RGB(hue: hue, saturation: s, brightness: b)

        // On-accent: a hue-tinted near-white or near-black, whichever reads
        // better on the solid accent.
        let lightOn = RGB(hue: hue, saturation: 0.06, brightness: 1)
        let darkOn = RGB(hue: hue, saturation: min(s, 0.6), brightness: 0.16)
        let on = contrast(lightOn.luminance, accent.luminance) >= contrast(darkOn.luminance, accent.luminance) ? lightOn : darkOn

        return (accent.color, on.color)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension SpaceAccent {
    /// Gamma-encoded sRGB, 0–1.
    struct RGB {
        var r: Double
        var g: Double
        var b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(gray: Double) {
            self.init(r: gray, g: gray, b: gray)
        }

        /// `hue`, `saturation`, `brightness` all 0–1.
        init(hue: Double, saturation: Double, brightness: Double) {
            let h = (hue - hue.rounded(.down)) * 6
            let c = brightness * saturation
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let m = brightness - c
            switch Int(h) {
            case 0: self.init(r: c + m, g: x + m, b: m)
            case 1: self.init(r: x + m, g: c + m, b: m)
            case 2: self.init(r: m, g: c + m, b: x + m)
            case 3: self.init(r: m, g: x + m, b: c + m)
            case 4: self.init(r: x + m, g: m, b: c + m)
            default: self.init(r: c + m, g: m, b: x + m)
            }
        }

        /// Approximate plain window background per scheme (relative
        /// luminance ≈ 0.03 dark, ≈ 0.88 light).
        static func windowBackground(darkUI: Bool) -> RGB {
            RGB(gray: darkUI ? 0.19 : 0.95)
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func lin(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /// `other` composited over this color at opacity `amount`.
        func mixed(with other: RGB, amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }

        var color: Color {
            Color(.sRGB, red: r, green: g, blue: b)
        }
    }
}

public extension EnvironmentValues {
    /// Text/icon color for content drawn on `Color.accentColor` (the
    /// selected command-bar row). Set alongside the accent by the window.
    @Entry var onAccentColor: Color = .white
}
