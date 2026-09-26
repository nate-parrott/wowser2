import SwiftUI

// Iterate on `AgentFruitIcon` here. The "In the sidebar" preview renders it
// through the real tab-icon path (`TabIconView` + `TabStyleButtonModifier`)
// between ordinary tabs, at real size, so you can judge it in context.

#Preview("Gallery") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([16, 32, 64] as [CGFloat], id: \.self) { size in
            HStack(spacing: size * 0.6) {
                ForEach(AgentFruitFlavor.allCases, id: \.self) { flavor in
                    VStack(spacing: 8) {
                        AgentFruitIcon(flavor: flavor, working: true, size: size)
                        AgentFruitIcon(flavor: flavor, working: false, size: size)
                    }
                }
            }
        }
        Text("Top: working · Bottom: idle").font(.caption).foregroundStyle(.secondary)
    }
    .padding(24)
}

#Preview("In the sidebar") {
    HStack(spacing: 24) {
        AgentTabPreviewSidebar()
            .environment(\.colorScheme, .light)
        AgentTabPreviewSidebar()
            .environment(\.colorScheme, .dark)
    }
    .padding(24)
    .background(Color.gray.opacity(0.3))
}

#Preview("Zoomed tab row") {
    // 4× so pixel-level detail is visible while tweaking.
    VStack(spacing: 0) {
        PreviewTabRow(icon: .favicon(URL(string: "https://github.com/favicon.ico")), title: "GitHub")
        PreviewTabRow(icon: .agentFruit(flavor: .cherry, working: true), title: "Fix the flaky test", selected: true)
    }
    .frame(width: 220)
    .scaleEffect(4, anchor: .topLeading)
    .frame(width: 880, height: 280, alignment: .topLeading)
    .padding(24)
}

/// A slice of the sidebar's tab list with agent tabs mixed in among regular ones.
private struct AgentTabPreviewSidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            PreviewTabRow(icon: .favicon(URL(string: "https://github.com/favicon.ico")), title: "wowser · Pull requests")
            PreviewTabRow(icon: .agentFruit(flavor: .cherry, working: true), title: "Fix the flaky test", selected: true)
            PreviewTabRow(icon: .favicon(URL(string: "https://news.ycombinator.com/favicon.ico")), title: "Hacker News")
            PreviewTabRow(icon: .agentFruit(flavor: .blueberry, working: false), title: "Summarize my inbox")
            PreviewTabRow(icon: .terminal(running: false), title: "~/Documents/SW")
            PreviewTabRow(icon: .agentFruit(flavor: .lime, working: true), title: "Book a table for Friday")
            PreviewTabRow(icon: .sfSymbol("magnifyingglass"), title: "swiftui timelineview")
        }
        .padding(8)
        .frame(width: UIConstants.defaultSidebarWidth)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Mirrors `RegularTabButton`'s layout without needing a live `BrowserStore` tab.
private struct PreviewTabRow: View {
    var icon: TabAppearance.Icon
    var title: String
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: icon)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: UIConstants.macTabHeight)
        .modifier(TabStyleButtonModifier(isSelected: selected, pressed: {}))
    }
}
