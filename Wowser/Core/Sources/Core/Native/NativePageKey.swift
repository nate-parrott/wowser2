import Foundation

// A NativePageKey represents a tab content type associated with native UI.
//
// Terminal and file-browser tabs use a synthetic `about:blank?native=…` URL and
// render via a `NativePageOverlay` on top of an idle WKWebView.
//
// VSCode is *real* web content (we run `code serve-web` on a deterministic
// loopback port) so its NativePageKey is just the live `http://127.0.0.1:<port>/?folder=…`
// URL itself — the underlying WKWebView loads it directly.
//
// `.vscodeLoading` is a transient sentinel: when the underlying webview's
// nav to a serve-web URL fails (cold start: server not yet listening), we
// redirect the webview to `about:blank?native=vscode-loading&folder=…`. That
// commits, the loading overlay mounts, polls until the server is up, and
// then navigates the webview to the real serve-web URL.
public enum NativePageKey: Hashable, Codable {
    case terminal(cwd: String?, runCommand: String? = nil)
    case vscode(folder: String?)
    case vscodeLoading(folder: String?)
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
        case "vscode-loading":
            self = .vscodeLoading(folder: url.queryParam(name: "folder"))
        case "files":
            self = .fileBrowser(path: url.queryParam(name: "path"))
        default:
            return nil
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
        case .vscodeLoading(let folder):
            var components = URLComponents()
            components.scheme = "about"
            components.path = "blank"
            var items = [URLQueryItem(name: "native", value: "vscode-loading")]
            if let folder { items.append(URLQueryItem(name: "folder", value: folder)) }
            components.queryItems = items
            return components.url!
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
        case .vscode, .vscodeLoading: return "VS Code"
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
        case .vscode(let folder), .vscodeLoading(let folder): return folder
        case .fileBrowser(let path): return path
        }
    }

    public var isTerminal: Bool { if case .terminal = self { return true } else { return false } }
    public var isVSCode: Bool {
        switch self {
        case .vscode, .vscodeLoading: return true
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
