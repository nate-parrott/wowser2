import Foundation

// `browser.fs` — local filesystem access for BrowserJS.
//
// Paths are absolute or `~`-relative. Text is exchanged as UTF-8 strings;
// binary data is exchanged as base64 (`encoding: 'base64'`). All work runs off
// the main thread.

public struct BrowserJSFileStat: Codable, Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var isDirectory: Bool
    public var size: Int?
    /// Unix seconds.
    public var modified: Double?
}

public struct BrowserJSTasksInfo: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var enabled: Bool
        public var schedule: String
        public var nextRunAt: Double?
        public var lastRunAt: Double?
        public var lastRunSummary: String?
        public var lastRunWasError: Bool
        public var dataFilePath: String
    }
    public var filePath: String
    public var dataDirectory: String
    public var tasks: [Task]
}

public struct BrowserJSFileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int?
    public var modified: Double?
}

public extension BrowserJSHost {
    func fsRead(path: String, encoding: String) async throws -> String {
        try await BrowserJSFileSystem.read(path: path, encoding: encoding)
    }
    func fsWrite(path: String, data: String, encoding: String, append: Bool) async throws {
        try await BrowserJSFileSystem.write(path: path, data: data, encoding: encoding, append: append)
    }
    func fsList(path: String) async throws -> [BrowserJSFileEntry] {
        try await BrowserJSFileSystem.list(path: path)
    }
    func fsStat(path: String) async throws -> BrowserJSFileStat {
        try await BrowserJSFileSystem.stat(path: path)
    }
    func fsRemove(path: String) async throws {
        try await BrowserJSFileSystem.remove(path: path)
    }
    func fsMkdir(path: String) async throws {
        try await BrowserJSFileSystem.mkdir(path: path)
    }
}

enum BrowserJSFileSystem {
    static func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw BrowserJSError.invalidArgs("path") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw BrowserJSError.invalidArgs("path must be absolute or start with ~: \(path)")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func decode(_ data: String, encoding: String) throws -> Data {
        switch encoding {
        case "utf8", "utf-8", "text":
            guard let d = data.data(using: .utf8) else { throw BrowserJSError.invalidArgs("data is not valid UTF-8") }
            return d
        case "base64", "binary":
            guard let d = Data(base64Encoded: data, options: [.ignoreUnknownCharacters]) else {
                throw BrowserJSError.invalidArgs("data is not valid base64")
            }
            return d
        default:
            throw BrowserJSError.invalidArgs("encoding must be 'utf8' or 'base64'")
        }
    }

    private static func encode(_ data: Data, encoding: String) throws -> String {
        switch encoding {
        case "utf8", "utf-8", "text":
            guard let s = String(data: data, encoding: .utf8) else {
                throw BrowserJSError.underlying("file is not valid UTF-8; read it with { encoding: 'base64' }")
            }
            return s
        case "base64", "binary":
            return data.base64EncodedString()
        default:
            throw BrowserJSError.invalidArgs("encoding must be 'utf8' or 'base64'")
        }
    }

    private static func wrap<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            do { return try body() }
            catch let e as BrowserJSError { throw e }
            catch { throw BrowserJSError.underlying(error.localizedDescription) }
        }.value
    }

    static func read(path: String, encoding: String) async throws -> String {
        try await wrap {
            let url = try resolve(path)
            let data = try Data(contentsOf: url)
            return try encode(data, encoding: encoding)
        }
    }

    static func write(path: String, data: String, encoding: String, append: Bool) async throws {
        try await wrap {
            let url = try resolve(path)
            let bytes = try decode(data, encoding: encoding)
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } else {
                try bytes.write(to: url, options: .atomic)
            }
        }
    }

    static func list(path: String) async throws -> [BrowserJSFileEntry] {
        try await wrap {
            let url = try resolve(path)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            return urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return BrowserJSFileEntry(
                    name: u.lastPathComponent,
                    path: u.path,
                    isDirectory: v?.isDirectory ?? false,
                    size: v?.fileSize,
                    modified: v?.contentModificationDate?.timeIntervalSince1970
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    static func stat(path: String) async throws -> BrowserJSFileStat {
        try await wrap {
            let url = try resolve(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return BrowserJSFileStat(path: url.path, exists: false, isDirectory: false, size: nil, modified: nil)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return BrowserJSFileStat(
                path: url.path,
                exists: true,
                isDirectory: isDir.boolValue,
                size: (attrs[.size] as? NSNumber)?.intValue,
                modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
            )
        }
    }

    static func remove(path: String) async throws {
        try await wrap {
            let url = try resolve(path)
            guard url.path != "/" && url.path != NSHomeDirectory() else {
                throw BrowserJSError.invalidArgs("refusing to remove \(url.path)")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func mkdir(path: String) async throws {
        try await wrap {
            let url = try resolve(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
