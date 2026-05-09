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
    @State private var pathIsDirectory: Bool = true

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
            openInOtherType(.fileBrowser(path: resolvedFolder))
        })
        menu.addItem(CallbackMenuItem(title: "Open in Terminal") {
            openInOtherType(.terminal(cwd: resolvedFolder, runCommand: nil))
        })
        menu.addItem(CallbackMenuItem(title: "Open in VS Code") {
            openInOtherType(.vscode(folder: resolvedFolder))
        })
        menu.addItem(CallbackMenuItem(title: "New Claude") {
            openInOtherType(.terminal(cwd: resolvedFolder, runCommand: "claude"))
        })
        menu.addItem(.separator())
        if let expandedPath {
            if pathIsDirectory {
                menu.addItem(CallbackMenuItem(title: "Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
                })
            } else {
                menu.addItem(CallbackMenuItem(title: "Open in Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
                })
            }
            menu.addItem(CallbackMenuItem(title: "Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(expandedPath, forType: .string)
            })
        }
        return menu
    }

    private var expandedPath: String? {
        guard let raw = currentKey.folderPath, !raw.isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
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
            let isDirectory: Bool
            if exists, isDir.boolValue {
                resolved = expanded
                isDirectory = true
            } else if exists {
                resolved = (expanded as NSString).deletingLastPathComponent
                isDirectory = false
            } else {
                resolved = rawPath
                isDirectory = true
            }
            DispatchQueue.main.async {
                self.resolvedFolder = resolved
                self.pathIsDirectory = isDirectory
            }
        }
    }
}
#endif
