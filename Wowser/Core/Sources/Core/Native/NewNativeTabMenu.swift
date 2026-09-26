#if os(macOS)
import SwiftUI
import AppKit

enum NewMenuItem: String, Equatable, Codable, CaseIterable {
    case terminal
    case files
    case vscode
    case claude
    case chat
    case tab
    case folder

    /// Items that open a tab and are offered as the new-menu's quick action.
    /// Order is the order shown in the menu (`.tab` and `.folder` are handled
    /// separately).
    static let tabKinds: [NewMenuItem] = [.terminal, .files, .vscode, .claude, .chat]

    var iconAndLabel: (String, String) {
        switch self {
        case .tab:
            return ("plus", "New Tab")
        case .terminal:
            return ("terminal", "New Terminal")
        case .files:
            return ("folder", "New Files")
        case .vscode:
            return ("chevron.left.forwardslash.chevron.right", "New VS Code")
        case .claude:
            return ("sparkles", "New Claude")
        case .chat:
            return ("bubble.left", "New Chat")
        case .folder:
            return ("square.stack", "New Folder…")
        }
    }

    /// The quick action shown in `FancyPlus`, persisted in `DefaultsKeys.newMenuQuickAction`.
    static var storedQuickAction: NewMenuItem {
        let item = NewMenuItem(rawValue: DefaultsKeys.newMenuQuickAction.stringValue()) ?? .chat
        return item == .tab ? .chat : item
    }

    func perform(windowID: ID<WindowState>) {
        switch self {
        case .tab:
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
        case .terminal:
            Self.openNative(windowID: windowID) { .terminal(cwd: $0, runCommand: nil) }
        case .files:
            Self.openNative(windowID: windowID) { .fileBrowser(path: $0) }
        case .vscode:
            Self.openNative(windowID: windowID) { .vscode(folder: $0) }
        case .claude:
            Self.openNative(windowID: windowID) { .terminal(cwd: $0, runCommand: "claude") }
        case .chat:
            Task { @MainActor in
                AgentChatTabs.newChat(windowID: windowID)
            }
        case .folder:
            newFolder(windowID: windowID)
        }
    }

    /// Resolve the folder for the new native tab, then open it. Uses the
    /// space's folder; failing that, the most recently used native folder in
    /// this space, or a folder the user picks. Whatever folder is chosen
    /// becomes the space's folder if it doesn't have one yet.
    private static func openNative(windowID: ID<WindowState>, _ makeKey: @escaping (String?) -> NativePageKey) {
        let state = BrowserStore.shared.model
        let profileID = state.windows[windowID]?.profile
        if let folder = profileID.flatMap({ state.profiles[$0]?.folderPath?.nilIfEmpty })
            ?? state.mostRecentNativeFolderPath(windowID: windowID) {
            openTab(makeKey(folder), folder: folder, windowID: windowID)
        } else {
            pickFolder { picked in
                guard let picked else { return }
                openTab(makeKey(picked), folder: picked, windowID: windowID)
            }
        }
    }

    private static func openTab(_ key: NativePageKey, folder: String, windowID: ID<WindowState>) {
        BrowserStore.shared.modify { state in
            if let profileID = state.windows[windowID]?.profile {
                state.setFolderIfMissing(path: folder, forProfile: profileID)
            }
            state.openTab(url: key.url, windowID: windowID)
        }
    }

    private static func pickFolder(_ completion: @escaping (String?) -> Void) {
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

    /// The "New…" menu: native tab kinds, New Folder, and installed webapps'
    /// "new" entry points. `didChoose` is called (before performing) when a
    /// `NewMenuItem` is picked.
    static func buildMenu(windowID: ID<WindowState>, didChoose: ((NewMenuItem) -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        func add(_ item: NewMenuItem) {
            let (symbol, label) = item.iconAndLabel
            let menuItem = CallbackMenuItem(title: label) {
                didChoose?(item)
                item.perform(windowID: windowID)
            }
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(menuItem)
        }
        tabKinds.forEach(add)
        menu.addItem(.separator())
        add(.folder)
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
}

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
            buildMenu: { NewMenuItem.buildMenu(windowID: windowID) }
        )
    }
}
#endif
