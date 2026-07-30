import SwiftUI
import ChatToys

/// Auto-generated visual identity for a space (profile), derived from its
/// title. Stores hues only — saturation/brightness/opacity are fixed at render
/// time so every theme stays within the same aesthetic guardrails.
public struct SpaceTheme: Equatable, Codable {
    /// Primary hue in degrees (0–360). Drives the tint color and the strong
    /// end of the background gradient.
    public var hue: Double
    /// Secondary hue for the soft end of the gradient. Always analogous to
    /// `hue` (a small offset) so the gradient can't clash.
    public var secondaryHue: Double
}

/// Curated palette the LLM picks from. Hues are hand-tuned to avoid muddy
/// in-between values; the gradient pair is derived analogously.
public enum SpacePalette: String, CaseIterable, Codable {
    case red, orange, amber, yellow, lime, green, teal, cyan, blue, indigo, violet, pink

    var hue: Double {
        switch self {
        case .red: return 6
        case .orange: return 26
        case .amber: return 40
        case .yellow: return 50
        case .lime: return 95
        case .green: return 140
        case .teal: return 172
        case .cyan: return 195
        case .blue: return 214
        case .indigo: return 243
        case .violet: return 268
        case .pink: return 330
        }
    }

    public var theme: SpaceTheme {
        // Analogous pair: shift the soft end ~22° toward the "cooler" side.
        SpaceTheme(hue: hue, secondaryHue: (hue + 22).truncatingRemainder(dividingBy: 360))
    }

    /// Deterministic fallback when the LLM is unavailable: stable palette
    /// choice from the title so a space at least gets *a* consistent theme.
    static func fallback(forTitle title: String) -> SpacePalette {
        let cases = SpacePalette.allCases
        var hash: UInt64 = 5381
        for b in title.lowercased().utf8 { hash = hash &* 33 &+ UInt64(b) }
        return cases[Int(hash % UInt64(cases.count))]
    }
}

public extension SpaceTheme {
    /// In-window tint. Also used as the selection background behind white
    /// text (search results), so its luminance is capped per-hue: yellows and
    /// greens are far brighter than blues at the same HSB brightness, so we
    /// walk brightness down until white text clears ~3:1 contrast.
    var tintColor: Color {
        let saturation = 0.65
        var brightness = 0.78
        while brightness > 0.35,
              Self.relativeLuminance(hue: hue, saturation: saturation, brightness: brightness) > 0.26 {
            brightness -= 0.02
        }
        return Color(hue: hue / 360, saturation: saturation, brightness: brightness)
    }

    /// Subtle, somewhat-transparent background gradient (soft secondary hue
    /// at the top fading into the primary hue at the bottom). Low opacity so
    /// it reads as a wash over the window material in both light and dark.
    /// `intensity` (0–2, user setting) scales the wash's opacity.
    func backgroundGradient(intensity: Double = 1) -> LinearGradient {
        let clamped = max(0, min(intensity, 2))
        return LinearGradient(
            colors: [
                Color(hue: secondaryHue / 360, saturation: 0.5, brightness: 0.9).opacity(min(0.05 * clamped, 1)),
                Color(hue: hue / 360, saturation: 0.55, brightness: 0.85).opacity(min(0.13 * clamped, 1)),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// WCAG relative luminance of an HSB color (contrast vs white is
    /// 1.05 / (L + 0.05)).
    internal static func relativeLuminance(hue: Double, saturation: Double, brightness: Double) -> Double {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func lin(_ v: Double) -> Double {
            let v = v + m
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

extension BrowserStore {
    /// Regenerates the emoji + theme for a space from its effective title
    /// (user title, else auto-title). Cheap to call repeatedly: no-ops when
    /// the title is empty or the theme was already generated for this title.
    public func regenerateSpaceTheme(profileID: ID<Profile>) async {
        struct Input { var title: String; var generatedFor: String? }
        let input: Input? = await readAsync { state in
            guard let profile = state.profiles[profileID] else { return nil }
            let title = (profile.title ?? profile.autoTitle)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Input(title: title, generatedFor: profile.themeGeneratedForTitle)
        }
        guard let input, !input.title.isEmpty, input.title != input.generatedFor else { return }

        let (emoji, palette) = await Self.generateEmojiAndPalette(forTitle: input.title)

        await modifyAsync { state in
            guard var profile = state.profiles[profileID] else { return }
            // The title may have changed while we were generating; only apply
            // if it still matches what we generated for.
            let currentTitle = (profile.title ?? profile.autoTitle)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard currentTitle == input.title else { return }
            profile.theme = palette.theme
            if let emoji { profile.emoji = emoji }
            profile.themeGeneratedForTitle = input.title
            state.profiles[profileID] = profile
        }
    }

    private static func generateEmojiAndPalette(forTitle title: String) async -> (emoji: String?, palette: SpacePalette) {
        struct Response: Codable {
            var emoji: String
            var color: String
        }
        let colorNames = SpacePalette.allCases.map(\.rawValue).joined(separator: ", ")
        let prompt = """
        A browser workspace ("space") is named "\(title)".
        Pick a visual identity for it:
        1. A single emoji that best represents the name. Prefer objects, places and symbols over faces.
        2. The best-fitting color, chosen ONLY from this list: \(colorNames)

        Respond in JSON only, in this exact format:
        {"emoji": "🌵", "color": "green"}
        """
        do {
            let resp = try await LLMs.currentOrThrow(json: true).completeJSONObject(
                prompt: [LLMMessage(role: .user, content: prompt)],
                type: Response.self
            )
            let palette = SpacePalette(rawValue: resp.color.lowercased().trimmingCharacters(in: .whitespaces))
                ?? .fallback(forTitle: title)
            // Guardrail: keep only the first grapheme and make sure it's
            // actually emoji-presenting, not a letter or word.
            let emoji: String? = resp.emoji.first.flatMap { char in
                char.unicodeScalars.first?.properties.isEmojiPresentation == true
                    || char.unicodeScalars.contains(where: { $0.properties.isEmojiModifierBase || $0.value == 0xFE0F })
                    ? String(char) : nil
            }
            return (emoji, palette)
        } catch {
            print("[SpaceTheme] generation failed (\(error)); using fallback palette")
            return (nil, .fallback(forTitle: title))
        }
    }
}
