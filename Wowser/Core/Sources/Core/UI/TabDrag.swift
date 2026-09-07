import Foundation
import UniformTypeIdentifiers

/// Drag payload for sidebar tabs. Drop targets read the tab ID as a plain
/// string; file tabs additionally carry the file URL so the tab can be dropped
/// anywhere that accepts files (Finder, a web page, another file browser).
extension NSItemProvider {
    static let tabDragTypeIdentifier = "com.wowser.tab-id"

    static func tabDrag(tabID: ID<Tab>, fileURL: URL?) -> NSItemProvider {
        let provider = NSItemProvider(object: tabID.raw as NSString)
        let idData = Data(tabID.raw.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: tabDragTypeIdentifier, visibility: .ownProcess) { completion in
            completion(idData, nil)
            return nil
        }
        if let fileURL {
            provider.registerObject(fileURL as NSURL, visibility: .all)
            provider.suggestedName = fileURL.lastPathComponent
        }
        return provider
    }

    var isTabDrag: Bool {
        hasItemConformingToTypeIdentifier(NSItemProvider.tabDragTypeIdentifier)
    }
}

extension Tab {
    /// The on-disk file a single-pane tab is showing (native file browser on a
    /// path, or a `file://` page), if any.
    var draggableFileURL: URL? {
        guard panes.count == 1, let url = panes.first?.info.url else { return nil }
        if let key = NativePageKey(url: url), case .fileBrowser(let path) = key, let path, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if url.isFileURL { return url }
        return nil
    }

    /// `draggableFileURL` narrowed to things worth handing to the default app:
    /// a finished download, or a file-browser target that looks like a file
    /// (has an extension — pure-data heuristic, no disk access). Never a
    /// partially-written download.
    var openableFileURL: URL? {
        guard let url = draggableFileURL else { return nil }
        if let download = panes.first?.download {
            return download.status == .completed ? url : nil
        }
        return url.pathExtension.isEmpty ? nil : url
    }
}
