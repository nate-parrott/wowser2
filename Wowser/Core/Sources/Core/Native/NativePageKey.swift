import Foundation

// A NativePageKey represents a tab content type that is rendered as a native overlay
// on top of a WKWebView (which actually loads about:blank). The overlay is shown by
// WrappedWebView when the tab's URL parses into a NativePageKey.
//
// We piggy-back on `about:blank?…` (matching the existing GeneratedPageKey convention,
// per Q57) so that omnibox typing, history, and tab persistence all "just work" — the
// URL is the source of truth.
public enum NativePageKey: Hashable, Codable {
    case terminal(id: String, cwd: String?)
    case vscode(id: String, folder: String?)
    case fileBrowser(id: String, path: String?)

    public init?(url: URL) {
        guard url.absoluteString.hasPrefix("about:blank") else { return nil }
        if let kind = url.queryParam(name: "native") {
            switch kind {
            case "terminal":
                let id = url.queryParam(name: "id") ?? UUID().uuidString
                let cwd = url.queryParam(name: "cwd")
                self = .terminal(id: id, cwd: cwd)
            case "vscode":
                let id = url.queryParam(name: "id") ?? UUID().uuidString
                let folder = url.queryParam(name: "folder")
                self = .vscode(id: id, folder: folder)
            case "files":
                let id = url.queryParam(name: "id") ?? UUID().uuidString
                let path = url.queryParam(name: "path")
                self = .fileBrowser(id: id, path: path)
            default:
                return nil
            }
            return
        }
        return nil
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "about"
        components.path = "blank"

        switch self {
        case .terminal(let id, let cwd):
            var items = [
                URLQueryItem(name: "native", value: "terminal"),
                URLQueryItem(name: "id", value: id),
            ]
            if let cwd { items.append(URLQueryItem(name: "cwd", value: cwd)) }
            components.queryItems = items
        case .vscode(let id, let folder):
            var items = [
                URLQueryItem(name: "native", value: "vscode"),
                URLQueryItem(name: "id", value: id),
            ]
            if let folder { items.append(URLQueryItem(name: "folder", value: folder)) }
            components.queryItems = items
        case .fileBrowser(let id, let path):
            var items = [
                URLQueryItem(name: "native", value: "files"),
                URLQueryItem(name: "id", value: id),
            ]
            if let path { items.append(URLQueryItem(name: "path", value: path)) }
            components.queryItems = items
        }

        return components.url!
    }

    public var displayTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .fileBrowser: return "Files"
        }
    }

    /// Stable per-tab id baked into the URL when the native page is opened.
    /// Used to detect that two URLs differing only in per-overlay state (cwd,
    /// folder, path) belong to the same underlying session.
    public var sessionID: String {
        switch self {
        case .terminal(let id, _): return "terminal:\(id)"
        case .vscode(let id, _): return "vscode:\(id)"
        case .fileBrowser(let id, _): return "files:\(id)"
        }
    }

    public static func newTerminal(cwd: String? = nil) -> NativePageKey {
        .terminal(id: UUID().uuidString, cwd: cwd)
    }

    public static func newVSCode(folder: String? = nil) -> NativePageKey {
        .vscode(id: UUID().uuidString, folder: folder)
    }

    public static func newFileBrowser(path: String? = nil) -> NativePageKey {
        .fileBrowser(id: UUID().uuidString, path: path)
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
        case .terminal(_, let cwd): return cwd
        case .vscode(_, let folder): return folder
        case .fileBrowser(_, let path): return path
        }
    }

    public var isTerminal: Bool { if case .terminal = self { return true } else { return false } }
    public var isVSCode: Bool { if case .vscode = self { return true } else { return false } }
    public var isFileBrowser: Bool { if case .fileBrowser = self { return true } else { return false } }
}
