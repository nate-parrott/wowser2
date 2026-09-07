import SwiftUI
import Foundation
import UniformTypeIdentifiers

// View modifier for handling tab drag and drop. Files dropped from Finder
// become file tabs at the drop position; images dragged out of web pages set
// the space's background.
struct SidebarDropTarget: ViewModifier {
    typealias DropDestinationProvider = (CGPoint, CGSize) -> TabDropDestination?

    let dropDestinationForPoint: DropDestinationProvider
    @State private var isTargeted = false
    @State private var size: CGSize = .zero
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID

    func body(content: Content) -> some View {
        content
            .measureSize({ self.size = $0 })
            .onDrop(of: ["public.text", "public.file-url", "public.image"], isTargeted: $isTargeted) { providers, point in
                // Tab drags carry a file URL too when the tab shows a file, so
                // check for our tab marker before treating this as a file drop.
                let foreign = providers.filter { !$0.isTabDrag }
                let fileProviders = foreign.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                if !fileProviders.isEmpty {
                    return handleFileDrop(providers: fileProviders, at: point)
                }
                if let imageProvider = foreign.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
                    return handleImageDrop(provider: imageProvider)
                }

                let dragTabIDString = providers.first?.loadObject(ofClass: String.self) { string, _ in
                    guard let string = string else { return }
                    handleDrop(tabIDString: string, at: point)
                }

                return dragTabIDString != nil
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
//            .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }

    private func handleDrop(tabIDString: String, at point: CGPoint) {
        let tabID = ID<Tab>(raw: tabIDString)
        guard let dest = dropDestinationForPoint(point, size) else { return }

        // Verify that we can move the tab to this destination
        guard BrowserStore.shared.model.canMove(tab: tabID, to: dest) else { return }

        // Perform the move operation
        BrowserStore.shared.modify { state in
            state.move(tab: tabID, to: dest, makeActiveInWindow: nil)
        }
    }

    // MARK: - File drops → file tabs

    private func handleFileDrop(providers: [NSItemProvider], at point: CGPoint) -> Bool {
        guard let windowID else { return false }
        // Resolve the destination now, on the main thread; provider loading
        // completes later on an arbitrary queue.
        let dest = dropDestinationForPoint(point, size)
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.url(fromDropItem: item), url.isFileURL else { return }
                DispatchQueue.main.async {
                    var tabID: ID<Tab>?
                    BrowserStore.shared.modify { state in
                        tabID = state.openFileTab(path: url.path, windowID: windowID, at: dest)
                    }
                    // Pop on the next turn so the row exists before the change it animates on.
                    if let tabID {
                        DispatchQueue.main.async {
                            BrowserStore.shared.modify { $0.popTab(id: tabID) }
                        }
                    }
                }
            }
        }
        return true
    }

    // MARK: - Image drops → space background

    private func handleImageDrop(provider: NSItemProvider) -> Bool {
        guard let targetProfileID = profileID
            ?? windowID.flatMap({ BrowserStore.shared.model.windows[$0]?.profile }) else { return false }

        // In-page image drags: load the raw data of the first image-conforming
        // representation.
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                BrowserStore.shared.setSpaceBackgroundImage(data: data, profileID: targetProfileID)
            }
            return true
        }
        return false
    }

    private static func url(fromDropItem item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }
}

// Extension to make it easy to apply the modifier
extension View {
    func sidebarDropTarget(dropDestinationForPoint: @escaping SidebarDropTarget.DropDestinationProvider) -> some View {
        self.modifier(SidebarDropTarget(dropDestinationForPoint: dropDestinationForPoint))
    }
}
