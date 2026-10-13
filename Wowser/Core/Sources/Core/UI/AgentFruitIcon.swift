import SwiftUI

/// Which little fruit an agent tab gets. Derived stably from the agent's
/// session key so each agent keeps its identity for its whole life.
public enum AgentFruitFlavor: String, Codable, CaseIterable, Equatable {
    case cherry
    case orange
    case blueberry
    case lime
    case peach

    static func flavor(forKey key: String) -> AgentFruitFlavor {
        var hash = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ Int(byte) }
        let all = AgentFruitFlavor.allCases
        return all[abs(hash) % all.count]
    }

    var topColor: Color {
        switch self {
        case .cherry: return Color(hex: 0xFF6B6E)
        case .orange: return Color(hex: 0xFFAE45)
        case .blueberry: return Color(hex: 0x7A9BFF)
        case .lime: return Color(hex: 0xA8E063)
        case .peach: return Color(hex: 0xFFB49A)
        }
    }

    var bottomColor: Color {
        switch self {
        case .cherry: return Color(hex: 0xE0393E)
        case .orange: return Color(hex: 0xF28A00)
        case .blueberry: return Color(hex: 0x4A6FE8)
        case .lime: return Color(hex: 0x6FBF2E)
        case .peach: return Color(hex: 0xF68D68)
        }
    }
}

/// The agent's tab/chat icon: Wowie, tinted with the agent's flavor color.
/// While the agent works it plays a looping animation; when idle it sits still.
struct AgentFruitIcon: View {
    var flavor: AgentFruitFlavor
    var working: Bool
    var size: CGFloat = 16

    var body: some View {
        WowieAvatar(animation: working ? .typing : nil, weight: 0.6)
            .foregroundStyle(flavor.bottomColor)
            .frame(width: size, height: size)
    }
}

/// An agent tab's icon: Wowie in the same accent color as the other glyph tab
/// icons (`TabIconView`'s SF Symbols), switching to the on-accent color on a
/// highlighted row. Animates while the agent works.
struct AgentTabIcon: View {
    var working: Bool
    var highlighted = false
    @Environment(\.onAccentColor) private var onAccentColor

    var body: some View {
        WowieAvatar(animation: working ? .typing : nil, weight: 0.5)
            .foregroundStyle(highlighted ? onAccentColor : Color.accentColor)
            .frame(width: 16, height: 16)
    }
}

// Previews: AgentFruitIconPreviews.swift
