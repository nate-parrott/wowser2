import SwiftUI

/// Replaces the URL in the omnibox while an agent attached to this window's
/// omnibox is working: a shimmering status line over a soft, slowly drifting
/// blurred gradient. Clicking reveals the agent's tab in the sidebar.
///
/// Observes the attached-agent status itself (rather than receiving it from
/// the toolbar's snapshot) so the frequently-changing detail text only
/// re-renders this view.
struct AttachedAgentStatusView: View {
    var windowID: ID<WindowState>
    var fgColor: HSBA?
    var fontSize: CGFloat = 12

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.attachedAgentStatus(windowID: windowID) }) { status in
            if let status {
                AttachedAgentStatusContent(status: status, fgColor: fgColor, fontSize: fontSize) {
                    AgentChatTabs.reveal(tabID: status.primary.tabID, windowID: windowID)
                }
            }
        }
    }
}

private struct AttachedAgentStatusContent: View {
    var status: AttachedAgentStatus
    var fgColor: HSBA?
    var fontSize: CGFloat = 12
    var onTap: () -> Void

    @State private var hovered = false

    private var flavor: AgentFruitFlavor { .flavor(forKey: status.primary.agentKey) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                AgentFruitIcon(flavor: flavor, working: status.primary.working, size: 14)
                ShimmerText(text: status.headline, active: status.primary.working)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if status.othersCount > 0 {
                    Text("+\(status.othersCount)")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .opacity(0.5)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: fontSize - 2, weight: .semibold))
                    .opacity(hovered ? 0.6 : 0)
            }
            .foregroundStyle(fgColor?.color ?? Color.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if status.primary.working {
                    DriftingGradientBackdrop(flavor: flavor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(status.primary.query.isEmpty ? "Show the agent" : "Agent: \(status.primary.query)")
    }
}

/// Text with a soft highlight that sweeps across while `active`.
private struct ShimmerText: View {
    var text: String
    var active: Bool

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t / 1.6).truncatingRemainder(dividingBy: 1)) // 0…1 sweep
                Text(text)
                    .overlay {
                        GeometryReader { geo in
                            let w = geo.size.width
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: Color.white.opacity(0.75), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: w * 0.6)
                            .offset(x: -w * 0.6 + (w * 1.6) * phase)
                            .blendMode(.plusLighter)
                        }
                        .mask(Text(text))
                    }
            }
        } else {
            Text(text)
        }
    }
}

/// Very subtle blurred colour wash that oscillates behind the status text.
private struct DriftingGradientBackdrop: View {
    var flavor: AgentFruitFlavor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = CGFloat(sin(t * 0.55)) // -1…1
            let x2 = CGFloat(cos(t * 0.37))
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(flavor.topColor)
                        .frame(width: geo.size.width * 0.5, height: geo.size.width * 0.5)
                        .offset(x: x * geo.size.width * 0.3, y: geo.size.height * 0.1)
                    Circle()
                        .fill(flavor.bottomColor)
                        .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                        .offset(x: x2 * geo.size.width * 0.35, y: -geo.size.height * 0.2)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blur(radius: 22)
                .opacity(0.16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .allowsHitTesting(false)
    }
}
