import Foundation

// Helpers are JS source files persisted to disk. They are concatenated in
// alpha order (Q18) and prepended to every `run_browser_js` evaluation.
//
// Default location: ~/Library/Application Support/Wowser/browserjs/helpers/<name>.js
public protocol BrowserJSHelpersProvider: Sendable {
    func saveHelper(name: String, content: String) throws
    func readHelper(name: String) throws -> String?
    func listHelpers() throws -> [(name: String, content: String)]
    func concatenatedHelpers() throws -> String
}

public final class BrowserJSHelpers: BrowserJSHelpersProvider, @unchecked Sendable {
    public static let shared: BrowserJSHelpers = BrowserJSHelpers()

    private let dir: URL
    private let queue = DispatchQueue(label: "BrowserJSHelpers")

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.dir = appSupport
                .appendingPathComponent("Wowser", isDirectory: true)
                .appendingPathComponent("browserjs", isDirectory: true)
                .appendingPathComponent("helpers", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    public func saveHelper(name: String, content: String) throws {
        let safe = try sanitize(name: name)
        try queue.sync {
            let url = dir.appendingPathComponent("\(safe).js")
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func readHelper(name: String) throws -> String? {
        let safe = try sanitize(name: name)
        return try queue.sync {
            let url = dir.appendingPathComponent("\(safe).js")
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    public func listHelpers() throws -> [(name: String, content: String)] {
        try queue.sync {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let jsURLs = urls
                .filter { $0.pathExtension == "js" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try jsURLs.map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let content = try String(contentsOf: url, encoding: .utf8)
                return (name, content)
            }
        }
    }

    public func concatenatedHelpers() throws -> String {
        let entries = try listHelpers()
        return entries.map { "// helper: \($0.name)\n\($0.content)\n" }.joined(separator: "\n")
    }

    private func sanitize(name: String) throws -> String {
        // Strict: alphanumerics, underscore, dash. No path components.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw NSError(domain: "BrowserJSHelpers", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid helper name: \(name)"])
        }
        return name
    }
}
