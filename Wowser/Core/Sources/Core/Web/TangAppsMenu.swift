#if os(macOS)
import SwiftUI
import AppKit

/// The "Apps" item in the menu bar: lists installed tang:// webapps and opens
/// them. Rebuilt from disk each time the menu opens.
public final class TangAppsMenuManager: NSObject, NSMenuDelegate {
    public static private(set) var shared: TangAppsMenuManager?

    private let openURL: (URL) -> Void
    private let menu = NSMenu(title: "Apps")
    private let item = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")

    public init(openURL: @escaping (URL) -> Void) {
        self.openURL = openURL
        super.init()
        item.submenu = menu
        menu.delegate = self
        if Self.shared == nil { Self.shared = self }
    }

    /// Insert the Apps menu into the main menu bar, before the Window menu.
    public func install() {
        guard let mainMenu = NSApp.mainMenu, !mainMenu.items.contains(item) else { return }
        let index = mainMenu.items.firstIndex(where: { $0.title == "Window" }) ?? mainMenu.items.count
        mainMenu.insertItem(item, at: index)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { TangAppRegistry.shared.reloadSync() }
        menu.removeAllItems()
        let apps = TangAppRegistry.shared.apps
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Apps Installed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for app in apps {
            let title = (app.manifest?.icon).map { "\($0) \(app.title)" } ?? app.title
            menu.addItem(CallbackMenuItem(title: title) { [openURL] in
                if let url = app.url { openURL(url) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: "Show Apps Folder in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([TangAppStore.shared.dir])
        })
    }
}

#endif
