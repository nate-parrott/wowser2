import SwiftUI
import Foundation

// A NativePageKey represents a tab content type associated with native UI.
//
// Terminal and file-browser tabs use a synthetic `about:blank?native=…` URL and
// render via a `NativePageOverlay` on top of an idle WKWebView.
//
// VSCode is *real* web content (we run `code serve-web` on a deterministic
// loopback port) so its NativePageKey is just the live `http://127.0.0.1:<port>/?folder=…`
// URL itself — the underlying WKWebView loads it directly.
public enum NativePageKey: Hashable, Codable {
    case terminal(cwd: String?, runCommand: String? = nil)
    case vscode(folder: String?)
    case fileBrowser(path: String?)

    public init?(url: URL) {
        if VSCodeConfig.isServeWebURL(url) {
            self = .vscode(folder: url.queryParam(name: "folder"))
            return
        }
        guard url.absoluteString.hasPrefix("about:blank") else { return nil }
        guard let kind = url.queryParam(name: "native") else { return nil }
        switch kind {
        case "terminal":
            self = .terminal(cwd: url.queryParam(name: "cwd"), runCommand: url.queryParam(name: "cmd"))
//        case "vscode-loading":
//            self = .vscodeLoading(folder: url.queryParam(name: "folder"))
        case "files":
            self = .fileBrowser(path: url.queryParam(name: "path"))
        default:
            return nil
        }
    }
    
    var kindString: String {
        // for BrowserJS
        switch self {
        case .terminal: return "terminal"
        case .vscode: return "vscode"
        case .fileBrowser: return "files"
        }
    }

    public var url: URL {
        switch self {
        case .vscode(let folder):
            var c = URLComponents(url: VSCodeConfig.serveWebBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
            if let folder, !folder.isEmpty {
                c.queryItems = [URLQueryItem(name: "folder", value: folder)]
            }
            return c.url!
        case .terminal(let cwd, let runCommand):
            var components = URLComponents()
            components.scheme = "about"
            components.path = "blank"
            var items = [URLQueryItem(name: "native", value: "terminal")]
            if let cwd { items.append(URLQueryItem(name: "cwd", value: cwd)) }
            if let runCommand { items.append(URLQueryItem(name: "cmd", value: runCommand)) }
            components.queryItems = items
            return components.url!
        case .fileBrowser(let path):
            var components = URLComponents()
            components.scheme = "about"
            components.path = "blank"
            var items = [URLQueryItem(name: "native", value: "files")]
            if let path { items.append(URLQueryItem(name: "path", value: path)) }
            components.queryItems = items
            return components.url!
        }
    }

    public var displayTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .fileBrowser: return "Files"
        }
    }

    /// The folder path this native session is associated with, if any
    /// (terminal cwd / vscode folder / file browser path). Lets the toolbar
    /// offer "open in <other native type>" against a single concept.
    ///
    /// NOTE: this is a pure-data accessor — the path may point at a file or
    /// a folder. Callers that need that distinction must check the disk at
    /// the view layer (see `OpenInOtherNativeMenu`).
    public var folderPath: String? {
        switch self {
        case .terminal(let cwd, _): return cwd
        case .vscode(let folder): return folder
        case .fileBrowser(let path): return path
        }
    }

    public var isTerminal: Bool { if case .terminal = self { return true } else { return false } }
    public var isVSCode: Bool {
        switch self {
        case .vscode: return true
        default: return false
        }
    }
    public var isFileBrowser: Bool { if case .fileBrowser = self { return true } else { return false } }
}

extension BrowserState {
    /// The folder path from the most recently accessed native (terminal /
    /// vscode / file browser) tab visible in the given window's current
    /// profile/space. Used to seed cwd/folder for new native tabs so the
    /// user lands in the same folder they were last working in.
    public func mostRecentNativeFolderPath(windowID: ID<WindowState>?) -> String? {
        guard let windowID, let win = windows[windowID] else { return nil }
        // Tabs visible in this window's current profile: ordinary tabs,
        // favorites, and tabs in the focused project (if any).
        var candidateTabIDs: [ID<Tab>] = win.tabs
        if let projID = win.focusedOnProject, let proj = projects[projID] {
            candidateTabIDs.append(contentsOf: proj.tabs)
        }
        candidateTabIDs.append(contentsOf: favorites(profileId: win.profile))

        let scored: [(Date, String)] = candidateTabIDs.compactMap { tabID in
            guard let tab = tabs[tabID] else { return nil }
            for pane in tab.panes.asArray {
                if let url = pane.info.url,
                   let key = NativePageKey(url: url),
                   let folder = key.folderPath, !folder.isEmpty {
                    return (tab.lastAccessed, folder)
                }
            }
            return nil
        }
        return scored.max(by: { $0.0 < $1.0 })?.1
    }
}

extension NativePageKey {
    /// Tidy rendering of a terminal cwd for a tab title/subtitle: "~", "/", or
    /// the last path component (narrow tab strips can't show more).
    static func prettyCwd(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if cwd == NSHomeDirectory() { return "~" }
        if cwd == "/" { return "/" }
        return (cwd as NSString).lastPathComponent
    }

    @ViewBuilder
    func favicon(size: CGFloat = 16) -> some View {
        // HACK: is it ok to drop size?
        switch self {
        case .terminal:
            TerminalFavicon()
        case .vscode:
            VSCodeFavicon()
        case .fileBrowser:
            FileBrowserFavicon()
        }
    }
    
    // String used in eg 'new terminal' search actions. Nonspecific
    var actionTitle: String {
        switch self {
        case .terminal(_, let cmd):
            if cmd == "claude" { return "New Claude" }
            return "Open Terminal"
        case .vscode: return "Open VS Code"
        case .fileBrowser: return "Open File Browser"
        }
    }
    
    // String served for history-based navs
    var historyBasedSearchResultTitle: String {
        switch self {
        case .terminal(let cwd, _):
            if let cwd {
                return cwd.lastPathComponent
            }
        case .vscode(let folder):
            if let folder {
                return folder.lastPathComponent
            }
        case .fileBrowser(let path):
            if let path {
                return path.lastPathComponent
            }
        }
        return self.actionTitle
    }
    
    var historyBasedSearchResultSubtitle: String? {
        switch self {
        case .terminal(let cwd, _):
            if let cwd {
                return "Terminal in \(cwd)"
            }
        case .vscode(let folder):
            if let folder {
                return "VS Code in \(folder)"
            }
        case .fileBrowser(let path):
            if let path {
                return "Files in \(path)"
            }
        }
        return nil
    }
    
    var suppressTitleFromWebview: Bool {
        switch self {
        case .terminal, .fileBrowser: return true
        case .vscode: return false
        }
    }
    
    func tabAppearance(info: WebContent.Info, baseInfo: WebContent.Info?) -> TabAppearance {
        var appearance = TabAppearance(
            title: info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty ?? info.url?.hostWithoutWWW ?? "",
            icon: .empty,
            urlFieldTextSelected: info.url?.absoluteString ?? "",
            urlFieldTextDeselected: info.url?.hostWithoutWWW ?? ""
        )
        switch self {
        case .terminal(let cwd, _):
            let command = info.terminalForegroundCommand?.nilIfEmpty
            appearance.icon = .terminal(running: command != nil)
            let titleFromTerm = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
            appearance.title = titleFromTerm ?? "Terminal"
            // While a command runs the title shows the command, so surface the
            // cwd underneath it — otherwise the title *is* the cwd.
            if command != nil {
                appearance.subtitle = NativePageKey.prettyCwd(cwd)
            }
            appearance.urlFieldTextSelected = appearance.title
            appearance.urlFieldTextDeselected = appearance.title
        case .vscode(let folder):
            appearance.icon = .vscode
            let liveTitle = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
            let folderName = folder.flatMap { ($0 as NSString).lastPathComponent.nilIfEmpty }
            appearance.title = liveTitle ?? folderName ?? "VS Code"
            appearance.urlFieldTextSelected = appearance.title
            appearance.urlFieldTextDeselected = appearance.title
        case .fileBrowser(let path):
            appearance.icon = .files
            let liveTitle = info.title?.nilIfEmpty ?? baseInfo?.title?.nilIfEmpty
            let pathName: String? = {
                guard let path else { return nil }
                if path == "/" { return "/" }
                return ((path as NSString).expandingTildeInPath as NSString).lastPathComponent.nilIfEmpty
            }()
            appearance.title = liveTitle ?? pathName ?? "Files"
            appearance.urlFieldTextSelected = appearance.title
            appearance.urlFieldTextDeselected = appearance.title
        }
        return appearance
    }
}
