#if os(macOS)
import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

struct FileBrowserOverlay: View {
    var sessionID: String
    var initialPath: String?
    var webContent: WebContent
    var isFocused: Bool

    @Environment(\.windowID) private var windowID

    @State private var entries: [FileEntry] = []
    @State private var selection: Set<FileEntry.ID> = []
    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\.name, order: .forward),
    ]
    @State private var loadError: String?
    /// Resolved once on appear. The overlay is keyed on the URL by
    /// `WrappedWebView`, so it re-mounts when the path changes — meaning
    /// this stays correct without re-checking on every body re-eval.
    @State private var pathIsDirectory: Bool = true

    private var paneID: ID<WebContent> { webContent.id }

    /// The URL the pane is keyed to. May point to either a directory (table
    /// view) or a single file (full-pane Quick Look).
    private var currentURL: URL {
        if let initialPath, !initialPath.isEmpty {
            return URL(fileURLWithPath: (initialPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var sortedEntries: [FileEntry] {
        // Always group folders first, then apply the user-chosen sort within
        // each group.
        let sorted = entries.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color("Background", bundle: .module))
        .background {
            // Hidden buttons for cmd+C / cmd+V keyboard shortcuts.
            ZStack {
                Button("") { copySelectionToPasteboard() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("") { pasteFromPasteboard() }
                    .keyboardShortcut("v", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onAppear {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDir)
            pathIsDirectory = exists && isDir.boolValue
            if pathIsDirectory {
                refresh()
            }
            updateTitle()
        }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            errorView(loadError)
        } else if pathIsDirectory {
            fileTable
        } else {
            QuickLookPreview(url: currentURL)
                .id(currentURL)
        }
    }

    @ViewBuilder private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var fileTable: some View {
        Table(sortedEntries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                FileNameCell(
                    entry: entry,
                    onDoubleClick: { handleDoubleClick(entry) },
                    onCmdClick: {
                        select(only: entry)
                        openInNewTab(entry, activate: false)
                    },
                    onOptionClick: {
                        select(only: entry)
                        openInSplitPane(entry)
                    },
                    onDropFiles: { urls in
                        if entry.isDirectory {
                            handleDrop(urls, into: entry.url)
                        }
                    }
                )
                .contextMenu { contextMenu(for: entry) }
            }

            TableColumn("Size", value: \.size) { entry in
                Text(entry.isDirectory ? "—" : formattedSize(entry.size))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            .width(min: 60, ideal: 90, max: 140)

            TableColumn("Modified", value: \.modifiedSortKey) { entry in
                Text(entry.modified.map(formattedDate) ?? "—")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            .width(min: 120, ideal: 160, max: 220)
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Drop on table chrome (not on a folder row) → drop into the
            // current folder.
            handleDrop(urls, into: currentURL)
            return true
        }
    }

    // MARK: - Click handling

    private func select(only entry: FileEntry) {
        selection = [entry.id]
    }

    private func handleDoubleClick(_ entry: FileEntry) {
        select(only: entry)
        if entry.isDirectory {
            navigate(to: entry.url)
        } else if isHTML(entry.url) {
            // HTML files load natively as file:// in the webview.
            webContent.webview.load(URLRequest(url: entry.url))
        } else {
            // All other files: navigate to a Quick Look pane on this path.
            navigate(to: entry.url)
        }
    }

    @ViewBuilder private func contextMenu(for entry: FileEntry) -> some View {
        Button("Open") {
            select(only: entry)
            handleDoubleClick(entry)
        }
        Button("Open in New Tab") { openInNewTab(entry, activate: true) }
        Button("Open in Split Pane") { openInSplitPane(entry) }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        if entry.isDirectory {
            Button("Open in Terminal") {
                BrowserStore.shared.modify { state in
                    state.openTab(url: NativePageKey.newTerminal(cwd: entry.url.path).url)
                }
            }
            Button("Open in VS Code") {
                BrowserStore.shared.modify { state in
                    state.openTab(url: NativePageKey.newVSCode(folder: entry.url.path).url)
                }
            }
        } else {
            Button("Open in Default App") { NSWorkspace.shared.open(entry.url) }
        }
        Divider()
        Button("Copy") {
            select(only: entry)
            copySelectionToPasteboard()
        }
        Button("Delete", role: .destructive) { delete(entry) }
    }

    // MARK: - Open actions

    private func openInNewTab(_ entry: FileEntry, activate: Bool) {
        let url = targetURL(for: entry)
        guard let windowID else {
            BrowserStore.shared.modify { state in state.openTab(url: url, activate: activate) }
            return
        }
        BrowserStore.shared.createTab(withURL: url, in: windowID, activate: activate, inCurrentSplit: false)
    }

    private func openInSplitPane(_ entry: FileEntry) {
        let url = targetURL(for: entry)
        guard let windowID else {
            BrowserStore.shared.modify { state in state.openTab(url: url) }
            return
        }
        BrowserStore.shared.createTab(withURL: url, in: windowID, activate: true, inCurrentSplit: true)
    }

    /// Folders and non-HTML files route through the native file-browser key
    /// (Quick Look) — so the webview can never download anything. HTML loads
    /// natively as a `file://` URL.
    private func targetURL(for entry: FileEntry) -> URL {
        if !entry.isDirectory, isHTML(entry.url) {
            return entry.url
        }
        return NativePageKey.newFileBrowser(path: entry.url.path).url
    }

    private func isHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    private func navigate(to url: URL) {
        let key = NativePageKey.fileBrowser(id: sessionID, path: url.path)
        webContent.webview.load(URLRequest(url: key.url))
    }

    // MARK: - Pasteboard

    private func selectedURLs() -> [URL] {
        entries.filter { selection.contains($0.id) }.map(\.url)
    }

    private func copySelectionToPasteboard() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    private func pasteFromPasteboard() {
        guard pathIsDirectory else { return }
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        handleDrop(urls, into: currentURL)
    }

    // MARK: - Drop / copy-into-folder

    private func handleDrop(_ urls: [URL], into destinationFolder: URL) {
        let fm = FileManager.default
        var anyCopied = false
        for src in urls {
            // Don't copy a folder into itself or into one of its descendants.
            if destinationFolder.path == src.path { continue }
            if destinationFolder.path.hasPrefix(src.path + "/") { continue }

            let dest = uniqueDestination(for: src, in: destinationFolder)
            do {
                try fm.copyItem(at: src, to: dest)
                anyCopied = true
            } catch {
                loadError = "Copy failed: \(error.localizedDescription)"
            }
        }
        if anyCopied {
            refresh()
        }
    }

    private func uniqueDestination(for src: URL, in dir: URL) -> URL {
        let name = src.lastPathComponent
        let candidate = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2..<1000 {
            let newName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let c = dir.appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: c.path) {
                return c
            }
        }
        return candidate
    }

    // MARK: - Listing / mutation

    private func refresh() {
        loadError = nil
        let url = currentURL
        let fm = FileManager.default
        do {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
            let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
            entries = urls.compactMap { fileURL in
                let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
                return FileEntry(
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate
                )
            }
        } catch {
            entries = []
            loadError = "Could not read \(url.path): \(error.localizedDescription)"
        }
    }

    private func delete(_ entry: FileEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            refresh()
        } catch {
            loadError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func updateTitle() {
        let title: String = {
            if currentURL.path == "/" { return "/" }
            let last = currentURL.lastPathComponent
            return last.isEmpty ? "Files" : last
        }()
        BrowserStore.shared.modify { state in
            state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
                pane.info.title = title
            }
        }
    }
}

private struct FileEntry: Identifiable, Hashable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
    var id: URL { url }

    /// Sortable key for the modified date — sorts missing dates to the end.
    var modifiedSortKey: Date { modified ?? .distantPast }
}

private struct FileNameCell: View {
    let entry: FileEntry
    let onDoubleClick: () -> Void
    let onCmdClick: () -> Void
    let onOptionClick: () -> Void
    let onDropFiles: ([URL]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background {
            if entry.isDirectory && isDropTargeted {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            }
        }
        .contentShape(Rectangle())
        .draggable(entry.url)
        .modifier(FolderDropModifier(
            isFolder: entry.isDirectory,
            isTargeted: $isDropTargeted,
            onDrop: onDropFiles
        ))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleClick() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).modifiers(.command).onEnded { onCmdClick() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).modifiers(.option).onEnded { onOptionClick() }
        )
    }
}

private struct FolderDropModifier: ViewModifier {
    let isFolder: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if isFolder {
            content.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

private func formattedSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

private func formattedDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}

#endif
