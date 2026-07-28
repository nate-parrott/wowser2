#if os(macOS)
import SwiftUI
import AppKit

/// Secondary "…" button in the new-tab row that opens a new native
/// (terminal / files / VS Code / Claude) tab. Mirrors the folder menu shown in
/// the toolbar of native tabs (`OpenInOtherNativeMenu`).
///
/// Seeds the folder from the most recently used native tab in this space; if
/// no native folder is open anywhere in the space, prompts the user to pick a
/// folder before opening the tab.
struct NewNativeTabMenu: View {
    let windowID: ID<WindowState>

    var body: some View {
        ToolbarPopUpButton(
            symbolName: "ellipsis",
            help: "Open a new terminal, files, or editor tab…",
            buildMenu: buildMenu
        )
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(CallbackMenuItem(title: "New Terminal") {
            open { .terminal(cwd: $0, runCommand: nil) }
        })
        menu.addItem(CallbackMenuItem(title: "New Files") {
            open { .fileBrowser(path: $0) }
        })
        menu.addItem(CallbackMenuItem(title: "New VS Code") {
            open { .vscode(folder: $0) }
        })
        menu.addItem(CallbackMenuItem(title: "New Claude") {
            open { .terminal(cwd: $0, runCommand: "claude") }
        })
        // Webapp "new" entry points from installed apps' manifests
        for (app, entry) in TangAppRegistry.shared.entryPoints(.new) {
            menu.addItem(CallbackMenuItem(title: entry.label) {
                var args: [String: Any] = ["windowId": windowID.raw]
                if let profile = BrowserStore.shared.model.windows[windowID]?.profile {
                    args["profileId"] = profile.raw
                }
                TangAppEntryPointRunner.run(entry, appSlug: app.slug, args: args, windowID: windowID)
            })
        }
        return menu
    }

    /// Resolve the folder for the new native tab, then open it. Uses the most
    /// recently used native folder in this space; if there is none, prompts the
    /// user to pick a folder before opening.
    private func open(_ makeKey: @escaping (String?) -> NativePageKey) {
        if let folder = BrowserStore.shared.model.mostRecentNativeFolderPath(windowID: windowID) {
            openTab(makeKey(folder))
        } else {
            pickFolder { picked in
                guard let picked else { return }
                openTab(makeKey(picked))
            }
        }
    }

    private func openTab(_ key: NativePageKey) {
        BrowserStore.shared.modify { state in
            state.openTab(url: key.url, windowID: windowID)
        }
    }

    private func pickFolder(_ completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder for the new tab"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }
}
#endif
