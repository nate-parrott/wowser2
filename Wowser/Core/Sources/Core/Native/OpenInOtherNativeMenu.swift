#if os(macOS)
import SwiftUI
import AppKit

/// Toolbar menu shown for native pages (terminal/vscode/file-browser) that
/// lets the user open the same folder in another native type.
///
/// Owns its own filesystem check: when the current `NativePageKey` is a
/// file-browser whose path turns out to point at a file (Quick Look mode),
/// we want "Open in Terminal/VS Code/Files" to act on that file's *parent*
/// folder. The check runs once per `folderPath` change on a background
/// queue and lives entirely in the view layer — `NativePageKey` itself
/// stays a pure-data type with no I/O in its accessors.
struct OpenInOtherNativeMenu: View {
    let currentKey: NativePageKey
    let openInOtherType: (NativePageKey) -> Void

    @State private var resolvedFolder: String?

    var body: some View {
        ToolbarPopUpButton(
            symbolName: "folder",
            help: "Open this folder in…",
            buildMenu: buildMenu
        )
        .onAppearOrChange(of: currentKey.folderPath) { newPath in
            recomputeFolderInfo(for: newPath)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(CallbackMenuItem(title: "Open in Files") {
            openInOtherType(.fileBrowser(id: UUID().uuidString, path: resolvedFolder))
        })
        menu.addItem(CallbackMenuItem(title: "Open in Terminal") {
            openInOtherType(.terminal(id: UUID().uuidString, cwd: resolvedFolder, runCommand: nil))
        })
        menu.addItem(CallbackMenuItem(title: "Open in VS Code") {
            openInOtherType(.vscode(id: UUID().uuidString, folder: resolvedFolder))
        })
        menu.addItem(CallbackMenuItem(title: "New Claude") {
            openInOtherType(.terminal(id: UUID().uuidString, cwd: resolvedFolder, runCommand: "claude"))
        })
        return menu
    }

    private func recomputeFolderInfo(for rawPath: String?) {
        guard let rawPath, !rawPath.isEmpty else {
            resolvedFolder = nil
            return
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        // File existence checks are cheap but should be off-main so we
        // don't stutter when SwiftUI rebuilds the toolbar.
        DispatchQueue.global(qos: .userInitiated).async {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
            let resolved: String
            if exists, isDir.boolValue {
                resolved = expanded
            } else if exists {
                resolved = (expanded as NSString).deletingLastPathComponent
            } else {
                resolved = rawPath
            }
            DispatchQueue.main.async {
                self.resolvedFolder = resolved
            }
        }
    }
}
#endif
