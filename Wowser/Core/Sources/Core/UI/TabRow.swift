import SwiftUI

// Individual regular tab row that looks up its own data by ID
struct RegularTabRow: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    @State private var isHovered = false
    @State private var popScale: CGFloat = 1
    
    var body: some View {
        // Look up the data from BrowserStore and generate a TabSnapshot
        WithSnapshotMain(store: BrowserStore.shared) { state -> TabSnapshot? in
            if let tab = state.tabs[tabID] {
                return TabSnapshot.from(tab: tab)
            } else {
                return nil
            }
        } main: { snapshot in
            if let snapshot = snapshot {
                RegularTabButton(
                    snapshot: snapshot,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    windowID: windowID
                )
                .help(snapshot.appearance.title)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .onDrag {
                    // WARNING: onDrag appears to leak the hosting view when clicked
                    NSItemProvider.tabDrag(tabID: tabID, fileURL: snapshot.fileURL)
                }
                .scaleEffect(popScale)
                .onChange(of: snapshot.animationCount) { _ in pop() }
            }
        }
    }

    /// Quick scale-up-and-settle to call attention to the row.
    private func pop() {
        withAnimation(.easeOut(duration: 0.12)) { popScale = 1.12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(duration: 0.35, bounce: 0.45)) { popScale = 1 }
        }
    }
}

// TabSnapshot represents the visual appearance data for a tab
struct TabSnapshot: Equatable {
    enum IconType: Equatable {
        case favicon(URL?)
        case sfSymbol(String)
        case empty
    }
    
    var tabID: ID<Tab>
    var appearance: TabAppearance
    var showSeparateSplitButton: Bool
    var isPip: Bool
    /// For file tabs: the file on disk, so dragging the tab also drags the file.
    var fileURL: URL?
    /// See `Tab.animationCount` — the row pops when this changes.
    var animationCount: Int?
    /// A finished file (download or file-browser file target) that the hover
    /// "open" button can hand to the default app.
    var openableFileURL: URL?

    // Factory method to create a snapshot from a tab
    static func from(tab: Tab) -> TabSnapshot {
        TabSnapshot(tabID: tab.id, appearance: tab.appearance(), showSeparateSplitButton: tab.panes.count > 1, isPip: tab.isPip, fileURL: tab.draggableFileURL, animationCount: tab.animationCount, openableFileURL: tab.openableFileURL)
    }
}

// Regular tab button component
private struct RegularTabButton: View {
    let snapshot: TabSnapshot
    let isSelected: Bool
    let isHovered: Bool
    let windowID: ID<WindowState>
    @State private var lastClickAt: Date?

    var body: some View {
        content
            .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
                let now = Date()
                if let last = lastClickAt, now.timeIntervalSince(last) < 0.5 {
                    lastClickAt = nil
                    renameTab(tabID: snapshot.tabID)
                } else {
                    lastClickAt = now
                    didClickTabToSelect(tabID: snapshot.tabID, windowID: windowID)
                }
            }))
            .contextMenu {
                TabContextMenu(tabID: snapshot.tabID, isFavorite: false)
            }
    }
    
    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            // Icon based on the type in the snapshot
            TabIconView(icon: snapshot.appearance.icon)
                .opacity(snapshot.appearance.isGhost || snapshot.appearance.isUnloaded ? 0.55 : 1)
                .modifier(TabBadgeModifier(badge: snapshot.appearance.badge))

            // Title (and optional subtitle) with truncation
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.appearance.title)
                    .opacity(snapshot.appearance.specialTitle ? 0.66 : 1)
                    .italic(snapshot.appearance.isCustomTitle)
                    .truncationMode(.tail)
                    .lineLimit(1)
                if let subtitle = snapshot.appearance.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(snapshot.appearance.isGhost || snapshot.appearance.isUnloaded ? 0.65 : 1)

            Spacer()

            // Close button that appears on hover
            if isHovered || isMobile() {
                HStack(spacing: 2) {
                    if snapshot.showSeparateSplitButton {
                        SeparateSplitTabsButton(tabID: snapshot.tabID)
                    }
                    #if os(macOS)
                    if let fileURL = snapshot.openableFileURL {
                        OpenFileButton(url: fileURL)
                    }
                    #endif
                    CloseTabButton(tabID: snapshot.tabID)
                }
            } else if snapshot.isPip {
                PipIndicatorButton(tabID: snapshot.tabID)
            }
        }
        .padding(.leading, isMobile() ? 14 : 8)
        .padding(.trailing, 4)
        // Fixed regardless of subtitle: rows must not resize when a terminal
        // tab starts or stops running a command.
        .frame(height: isMobile() ? 44 : UIConstants.macTabHeight)
        .contentShape(Rectangle())
    }
}

/// Attention marker pinned to the top-right corner of a tab's favicon, with a
/// 1.5pt ring masked out of the icon around it. See `TabAppearance.Badge`.
struct TabBadgeModifier: ViewModifier {
    var badge: TabAppearance.Badge?

    private let margin: CGFloat = 1.5
    private var badgeSize: CGFloat {
        switch badge {
        case .dot: return 6
        case .cursor: return 8
        case nil: return 0
        }
    }
    /// Badge center, relative to a 16pt icon's top-right corner.
    private var badgeCenter: CGPoint { CGPoint(x: 16 - 2, y: 2) }

    func body(content: Content) -> some View {
        if let badge {
            content
                .mask {
                    ZStack {
                        Rectangle()
                        Circle()
                            .frame(width: badgeSize + margin * 2, height: badgeSize + margin * 2)
                            .position(badgeCenter)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .overlay {
                    TabBadgeView(badge: badge)
                        .frame(width: badgeSize, height: badgeSize)
                        .position(badgeCenter)
                }
                .frame(width: 16, height: 16)
        } else {
            content
        }
    }
}

struct TabBadgeView: View {
    var badge: TabAppearance.Badge

    var body: some View {
        switch badge {
        case .dot:
            Circle()
                .fill(Color.accentColor)
        case .cursor:
            Image(systemName: "cursorarrow")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

struct NewTabCell: View {
    var windowID: ID<WindowState>
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: .sfSymbol("plus"))
                .accentColor(Color.primary)
                .opacity(0.4)
//                .saturation(0)
//                .opacity(0.5)
            Text("New Tab")
                .opacity(0.4)
                .lineLimit(1)
            Spacer()
            #if os(macOS)
            NewNativeTabMenu(windowID: windowID)
                .opacity(0.4)
            #endif
        }
        .padding(.leading, isMobile() ? 14 : 8)
        .padding(.trailing, 4)
        .frame(height: isMobile() ? 44 : UIConstants.macTabHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .modifier(TabStyleButtonModifier(isSelected: false, pressed: {
            BrowserStore.shared.createTab(
                withURL: nil,
                in: windowID,
                activate: true,
                inCurrentSplit: isOpenInSplitViewModifierKeyPressed() || multiSelectModifierPressed()
            )
            // Show search overlay to enter URL
            BrowserStore.shared.modify { state in
                state.windows[windowID]?.searchOverlayActive = true
            }
        }))
    }
}


#if os(macOS)
private struct OpenFileButton: View {
    var url: URL

    var body: some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            Image(systemName: "arrow.up.forward.app")
                .help("Open in Default App")
        }
        .buttonStyle(TabAccessoryButtonStyle())
    }
}
#endif

private struct CloseTabButton: View {
    var tabID: ID<Tab>
    
    var body: some View {
        Button(action: {
            closeTab(tabID: tabID)
        }) {
            Image(systemName: "xmark")
                .help("Close Tab")
        }
        .buttonStyle(TabAccessoryButtonStyle())
    }
}

// Shown in the trailing position (same metrics as the close button) when a
// tab is in pip mode. Clicking toggles the floating panel, same as clicking
// the row itself.
private struct PipIndicatorButton: View {
    var tabID: ID<Tab>

    var body: some View {
        Button(action: {
            BrowserStore.shared.modify { state in
                state.togglePipOpen(tabId: tabID)
            }
        }) {
            Image(systemName: "pip")
                .help("Picture in Picture")
        }
        .buttonStyle(TabAccessoryButtonStyle())
    }
}

private struct SeparateSplitTabsButton: View {
    var tabID: ID<Tab>
    
    var body: some View {
        Button(action: {
            BrowserStore.shared.modify { state in
                state.separateSplitTabs(tabId: tabID)
            }
        }) {
            Image(systemName: "arrow.trianglehead.branch")
                .help("Separate Split Tabs")
        }
        .buttonStyle(TabAccessoryButtonStyle())
    }
}

struct TabAccessoryButtonStyle: ButtonStyle {
    @State private var hovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.secondary)
            .padding(6)
            .frame(both: isMobile() ? 40 : nil)
            .contentShape(Rectangle())
            .background {
                if hovered {
                    Circle()
                        .foregroundStyle(.primary)
                        .opacity(0.1)
                }
            }
            .onHover(perform: { self.hovered = $0 })
    }
}
