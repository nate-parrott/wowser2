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

/// A cute 16×16 fruit-with-eyes tab icon for agent tabs. While the agent works
/// its eyes are open and glance around (with the odd blink); when the agent is
/// idle, waiting on the user, the fruit dozes with closed eyes.
struct AgentFruitIcon: View {
    var flavor: AgentFruitFlavor
    var working: Bool
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if working {
                TimelineView(.periodic(from: .now, by: 0.7)) { context in
                    fruit(eyes: eyePhase(at: context.date))
                }
            } else {
                fruit(eyes: .closed)
            }
        }
        .frame(width: size, height: size)
    }

    private enum EyePhase: Equatable {
        case open(glance: CGFloat) // -1…1 pupil offset
        case blink
        case closed
    }

    private func eyePhase(at date: Date) -> EyePhase {
        // Deterministic from wall clock so every row's fruit stays in sync
        // without any stored state.
        let tick = Int(date.timeIntervalSinceReferenceDate / 0.7)
        if tick % 6 == 5 { return .blink }
        switch tick % 3 {
        case 0: return .open(glance: -1)
        case 1: return .open(glance: 1)
        default: return .open(glance: 0)
        }
    }

    @ViewBuilder
    private func fruit(eyes: EyePhase) -> some View {
        let bodySize = size * 0.82
        ZStack {
            // Leaf
            Ellipse()
                .fill(Color(hex: 0x4E9F3D))
                .frame(width: size * 0.32, height: size * 0.18)
                .rotationEffect(.degrees(-32))
                .offset(x: size * 0.14, y: -bodySize * 0.5)

            // Body
            Circle()
                .fill(LinearGradient(
                    colors: [flavor.topColor, flavor.bottomColor],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: bodySize, height: bodySize)
                .overlay {
                    // Soft top-left sheen
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: bodySize * 0.3, height: bodySize * 0.22)
                        .blur(radius: 1)
                        .offset(x: -bodySize * 0.2, y: -bodySize * 0.26)
                }
                .overlay {
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }

            // Face
            face(eyes: eyes)
                .offset(y: size * 0.05)
        }
        .frame(width: size, height: size)
        .offset(y: size * 0.04)
    }

    @ViewBuilder
    private func face(eyes: EyePhase) -> some View {
        let eyeSpacing = size * 0.16
        HStack(spacing: eyeSpacing) {
            eye(phase: eyes)
            eye(phase: eyes)
        }
    }

    @ViewBuilder
    private func eye(phase: EyePhase) -> some View {
        let eyeW = size * 0.14
        switch phase {
        case .open(let glance):
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: eyeW, height: eyeW)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: eyeW * 0.36, height: eyeW * 0.36)
                    .offset(x: -eyeW * 0.16, y: -eyeW * 0.16)
            }
            .offset(x: glance * eyeW * 0.3)
        case .blink, .closed:
            ClosedEyeShape()
                .stroke(Color.black.opacity(0.75), style: StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round))
                .frame(width: eyeW, height: eyeW * 0.6)
        }
    }
}

/// A gentle downward arc — a happily closed eye.
private struct ClosedEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return p
    }
}

#Preview {
    HStack(spacing: 12) {
        ForEach(AgentFruitFlavor.allCases, id: \.self) { flavor in
            VStack(spacing: 8) {
                AgentFruitIcon(flavor: flavor, working: true, size: 32)
                AgentFruitIcon(flavor: flavor, working: false, size: 32)
            }
        }
    }
    .padding()
}
