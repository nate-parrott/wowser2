import SwiftUI
import UniformTypeIdentifiers

/// A drop zone along the right edge of the window content that accepts URL
/// drags (e.g. a link dragged out of a web page). While a URL drag hovers the
/// zone, a small floating target chip appears; dropping opens the URL as a new
/// split pane in the current tab.
///
/// File drags (Finder) are rejected by `validateDrop` so they still fall
/// through to the web page below.
struct URLSplitDropTargetModifier: ViewModifier {
    let windowID: ID<WindowState>

    @State private var isTargeted = false

    private static let stripWidth: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: Self.stripWidth)
                    .onDrop(of: [.url], delegate: URLSplitDropDelegate(windowID: windowID, isTargeted: $isTargeted))
            }
            .overlay(alignment: .trailing) {
                if isTargeted {
                    URLSplitDropChip()
                        .padding(.trailing, 16)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct URLSplitDropChip: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 22, weight: .medium))
            Text("Open in Split")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 2)
    }
}

private struct URLSplitDropDelegate: DropDelegate {
    let windowID: ID<WindowState>
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // Accept web URLs only; let Finder file drags fall through to the page.
        info.hasItemsConforming(to: [.url]) && !info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.url])
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }
            guard let url, !url.isFileURL else { return }
            DispatchQueue.main.async {
                BrowserStore.shared.modify { state in
                    state.openURLInSplit(url, windowID: windowID)
                }
            }
        }
        return true
    }
}

extension BrowserState {
    /// Appends a new pane loading `url` to the window's current tab and
    /// focuses it. If the window has no current tab, opens a new tab instead.
    mutating func openURLInSplit(_ url: URL, windowID: ID<WindowState>) {
        if let tabID = windows[windowID]?.currentTab, tabs[tabID] != nil {
            modifyTab(id: tabID) { tab in
                tab.panes.append(Pane(id: .assign(), info: .init(url: url)))
                tab.focusedPaneIdx = tab.panes.count - 1
            }
        } else {
            let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: .init(url: url))])
            let location = insertionIndex(window: windowID, spawningTabId: nil)
            insertTab(tab, location: location, inWindow: windowID)
            activate(tabId: tab.id, in: windowID)
        }
    }
}

extension View {
    /// Adds a right-edge drop zone that opens dropped URLs in a split pane.
    func urlSplitDropTarget(windowID: ID<WindowState>) -> some View {
        modifier(URLSplitDropTargetModifier(windowID: windowID))
    }
}
