#if DEBUG
import Cocoa

/// Debug-only: copies the running .app bundle into /Applications as "Wowser prod.app".
enum PromoteToProd {
    static let destination = URL(fileURLWithPath: "/Applications/Wowser prod.app")

    /// Adds a "Promote to Prod" item at the end of the File menu.
    static func installMenuItem() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        fileMenu.addItem(.separator())
        let item = NSMenuItem(title: "Promote to Prod", action: #selector(Actions.promoteToProd(_:)), keyEquivalent: "")
        item.target = Actions.shared
        fileMenu.addItem(item)
    }

    final class Actions: NSObject {
        static let shared = Actions()

        @objc func promoteToProd(_ sender: Any?) {
            let source = Bundle.main.bundleURL

            let confirm = NSAlert()
            confirm.messageText = "Promote to Prod?"
            confirm.informativeText = "Copy\n\(source.path)\nto\n\(destination.path)\n\nAny existing app there will be replaced."
            confirm.addButton(withTitle: "Promote")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            do {
                try PromoteToProd.copyBundle(from: source, to: PromoteToProd.destination)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Promote to Prod failed"
                alert.informativeText = "\(error)"
                alert.runModal()
                return
            }

            let done = NSAlert()
            done.messageText = "Promoted to Prod"
            done.informativeText = destination.path
            done.addButton(withTitle: "OK")
            done.addButton(withTitle: "Reveal in Finder")
            if done.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    /// Copy to a sibling temp bundle first, then swap it into place, so a failed
    /// copy never leaves a half-written app at the destination.
    fileprivate static func copyBundle(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).promoting-\(ProcessInfo.processInfo.processIdentifier)")

        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: source, to: staging)
        defer { try? fm.removeItem(at: staging) }

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}
#endif
