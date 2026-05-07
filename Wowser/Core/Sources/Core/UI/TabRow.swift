import SwiftUI

// Individual regular tab row that looks up its own data by ID
struct RegularTabRow: View {
    let tabID: ID<Tab>
    let isSelected: Bool
    let windowID: ID<WindowState>
    @State private var isHovered = false
    
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
                    // Create a drag item with the tab ID as text
                    NSItemProvider(object: tabID.raw as NSString)
                }
            }
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
    
    // Factory method to create a snapshot from a tab
    static func from(tab: Tab) -> TabSnapshot {
        TabSnapshot(tabID: tab.id, appearance: tab.appearance(), showSeparateSplitButton: tab.panes.count > 1)
    }
}

// Regular tab button component
private struct RegularTabButton: View {
    let snapshot: TabSnapshot
    let isSelected: Bool
    let isHovered: Bool
    let windowID: ID<WindowState>
    
    var body: some View {
        content
            .modifier(TabStyleButtonModifier(isSelected: isSelected, pressed: {
                didClickTabToSelect(tabID: snapshot.tabID, windowID: windowID)
            }))
            .contextMenu {
                TabContextMenu(tabID: snapshot.tabID, isFavorite: false)
            }
    }
    
    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            // Icon based on the type in the snapshot
            TabIconView(icon: snapshot.appearance.icon)
                .opacity(snapshot.appearance.isGhost ? 0.55 : 1)

            // Title (and optional subtitle) with truncation
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.appearance.title)
                    .opacity(snapshot.appearance.specialTitle ? 0.66 : 1)
                    .truncationMode(.tail)
                    .lineLimit(1)
                if let subtitle = snapshot.appearance.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(snapshot.appearance.isGhost ? 0.65 : 1)

            Spacer()

            // Close button that appears on hover
            if isHovered || isMobile() {
                HStack(spacing: 2) {
                    if snapshot.showSeparateSplitButton {
                        SeparateSplitTabsButton(tabID: snapshot.tabID)
                    }
                    CloseTabButton(tabID: snapshot.tabID)
                }
            }
        }
        .padding(.leading, isMobile() ? 14 : 8)
        .padding(.trailing, 4)
        .frame(height: snapshot.appearance.subtitle != nil ? (isMobile() ? 56 : 40) : (isMobile() ? 44 : 30))
        .contentShape(Rectangle())
    }
}

struct NewTabCell: View {
    var windowID: ID<WindowState>
    
    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: .sfSymbol("plus"))
                .saturation(0)
                .opacity(0.5)
            Text("New Tab")
                .opacity(0.4)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, isMobile() ? 14 : 8)
        .padding(.trailing, 4)
        .frame(height: isMobile() ? 44 : 30)
        .contentShape(Rectangle())
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
