import Foundation

public extension Notification.Name {
    /// A branch's files changed on disk through `ShellBranchStore`.
    /// `userInfo["branch"]` is the branch name.
    static let shellBranchDidChange = Notification.Name("ShellBranchDidChange")
    /// A branch's private storage changed. `userInfo`: `branch`, `key`.
    static let shellStorageDidChange = Notification.Name("ShellStorageDidChange")
}

/// Branches of the browser UI, as folders on disk.
///
///     ~/Library/Application Support/Wowser/Shell[-dev]/
///       branches/<name>/            the branch: manifest.json + TS/JS files
///       history/<name>/<seq>/       checkpoints (whole-folder snapshots)
///       history/<name>/index.json   undo / redo stacks
///       history/<name>/good/        last version that mounted without error
///       storage/<name>.json         the branch's `storage` key/value data
///
/// Branches are small folders of text, so versioning is deliberately dumb:
/// a checkpoint is a copy of the folder. `undo` swaps the working folder with
/// the newest checkpoint; `redo` swaps back.
///
/// `stock` is the built-in UI. It is re-copied from the app bundle whenever
/// the bundle changes and cannot be edited — fork it.
public final class ShellBranchStore {
    public static let shared = ShellBranchStore(root: ShellBranchStore.defaultRoot, bundledSeeds: ShellKit.bundledBranches)

    public static let stockName = "stock"
    static let maxCheckpoints = 60

    public static var defaultRoot: URL {
        AppPaths.applicationSupport
            .appendingPathComponent("Wowser", isDirectory: true)
            .appendingPathComponent("Shell" + dataDirSuffix(), isDirectory: true)
    }

    public let root: URL
    private let bundledSeeds: URL?
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()

    public init(root: URL, bundledSeeds: URL?) {
        self.root = root
        self.bundledSeeds = bundledSeeds
    }

    // MARK: Types

    public struct Manifest: Codable, Equatable {
        public var name: String?
        public var description: String?
        public var entry: [String: String]?
        /// Seeds only: copy this bundled branch first, then overlay.
        public var seedBase: String?
    }

    public struct BranchInfo: Codable, Equatable, Identifiable {
        public var id: String { name }
        /// Folder name; the identifier used everywhere.
        public var name: String
        public var title: String
        public var description: String
        public var isBuiltin: Bool
        public var canUndo: Bool
        public var canRedo: Bool
        public var checkpointCount: Int
        public var path: String
    }

    public struct Checkpoint: Codable, Equatable, Identifiable {
        public var id: Int
        public var label: String
        public var date: Date
    }

    private struct HistoryIndex: Codable {
        var next = 1
        var undo: [Checkpoint] = []
        var redo: [Checkpoint] = []
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case invalidName(String)
        case invalidPath(String)
        case noSuchBranch(String)
        case alreadyExists(String)
        case readOnly(String)
        case nothingToUndo
        case nothingToRedo
        case noGoodVersion

        public var errorDescription: String? {
            switch self {
            case .invalidName(let n): return "Invalid branch name \"\(n)\". Use letters, digits, '-' and '_' (max 64)."
            case .invalidPath(let p): return "Invalid file path \"\(p)\". Paths are relative to the branch folder and may not contain '..' or hidden components."
            case .noSuchBranch(let n): return "No branch named \"\(n)\"."
            case .alreadyExists(let n): return "A branch named \"\(n)\" already exists."
            case .readOnly(let n): return "\"\(n)\" is the built-in UI and can't be edited. Create a branch from it first."
            case .nothingToUndo: return "Nothing to undo."
            case .nothingToRedo: return "Nothing to redo."
            case .noGoodVersion: return "No known-good version of this branch has been recorded yet."
            }
        }
    }

    // MARK: Paths

    private var branchesDir: URL { root.appendingPathComponent("branches", isDirectory: true) }
    private var historyDir: URL { root.appendingPathComponent("history", isDirectory: true) }
    private var storageDir: URL { root.appendingPathComponent("storage", isDirectory: true) }

    public func directory(for branch: String) -> URL {
        branchesDir.appendingPathComponent(branch, isDirectory: true)
    }

    private func historyDirectory(for branch: String) -> URL {
        historyDir.appendingPathComponent(branch, isDirectory: true)
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
        }
    }

    /// Normalise a branch-relative path, rejecting anything that could leave
    /// the folder or touch hidden files.
    public static func safeRelativePath(_ path: String) -> String? {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." || part.hasPrefix(".") || part.contains("\\") || part.contains("\0") { return nil }
            parts.append(String(part))
        }
        if parts.isEmpty || parts.count > 12 { return nil }
        return parts.joined(separator: "/")
    }

    private func requireBranch(_ name: String) throws -> URL {
        guard Self.isValidName(name) else { throw StoreError.invalidName(name) }
        let dir = directory(for: name)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw StoreError.noSuchBranch(name)
        }
        return dir
    }

    // MARK: Seeding

    /// Copy the bundled branches into place. `stock` is always refreshed to
    /// match the bundle; other seeds are only created when missing.
    public func seedIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        try? fm.createDirectory(at: branchesDir, withIntermediateDirectories: true)
        guard let bundledSeeds,
              let seeds = try? fm.contentsOfDirectory(at: bundledSeeds, includingPropertiesForKeys: nil)
        else { return }
        for seed in seeds where seed.hasDirectoryPath {
            let name = seed.lastPathComponent
            guard Self.isValidName(name) else { continue }
            let dest = directory(for: name)
            let isStock = name == Self.stockName
            if fm.fileExists(atPath: dest.path) {
                guard isStock, Self.treeSignature(seed) != Self.treeSignature(dest) else { continue }
                try? fm.removeItem(at: dest)
            }
            let manifest = Self.readManifest(in: seed)
            do {
                if let base = manifest.seedBase, Self.isValidName(base) {
                    try copyTree(from: bundledSeeds.appendingPathComponent(base, isDirectory: true), to: dest)
                    try overlayTree(from: seed, onto: dest)
                    // The copy is a normal branch from here on.
                    var m = manifest
                    m.seedBase = nil
                    if let data = try? Self.prettyEncoder.encode(m) {
                        try? data.write(to: dest.appendingPathComponent("manifest.json"))
                    }
                } else {
                    try copyTree(from: seed, to: dest)
                }
            } catch {
                print("[Shell] failed to seed branch \(name): \(error)")
            }
        }
    }

    // MARK: Listing

    public func list() -> [BranchInfo] {
        lock.lock(); defer { lock.unlock() }
        let dirs = (try? fm.contentsOfDirectory(at: branchesDir, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .filter { $0.hasDirectoryPath && Self.isValidName($0.lastPathComponent) }
            .map { info(for: $0.lastPathComponent) }
            .sorted { a, b in
                if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    public func exists(_ name: String) -> Bool {
        (try? requireBranch(name)) != nil
    }

    public func info(for name: String) -> BranchInfo {
        let manifest = Self.readManifest(in: directory(for: name))
        let index = readIndex(name)
        return BranchInfo(
            name: name,
            title: manifest.name ?? name,
            description: manifest.description ?? "",
            isBuiltin: name == Self.stockName,
            canUndo: !index.undo.isEmpty,
            canRedo: !index.redo.isEmpty,
            checkpointCount: index.undo.count,
            path: directory(for: name).path
        )
    }

    public func manifest(_ name: String) -> Manifest {
        Self.readManifest(in: directory(for: name))
    }

    /// The entry module for a platform ("mac" / "ios"), from the manifest.
    public func entry(branch: String, platform: String) -> String {
        manifest(branch).entry?[platform] ?? "\(platform)/index"
    }

    private static func readManifest(in dir: URL) -> Manifest {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return Manifest() }
        return m
    }

    // MARK: Create / delete

    @discardableResult
    public func create(name: String, from source: String = ShellBranchStore.stockName, title: String? = nil, description: String? = nil) throws -> BranchInfo {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidName(name) else { throw StoreError.invalidName(name) }
        let src = try requireBranch(source)
        let dest = directory(for: name)
        guard !fm.fileExists(atPath: dest.path) else { throw StoreError.alreadyExists(name) }
        try copyTree(from: src, to: dest)
        var m = Self.readManifest(in: dest)
        m.name = title ?? name
        if let description { m.description = description }
        m.seedBase = nil
        try Self.prettyEncoder.encode(m).write(to: dest.appendingPathComponent("manifest.json"))
        // A fork starts with its parent's storage (layout choices etc.).
        let parentStorage = storageDir.appendingPathComponent(source + ".json")
        if fm.fileExists(atPath: parentStorage.path) {
            try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: parentStorage, to: storageDir.appendingPathComponent(name + ".json"))
        }
        notifyChanged(name)
        return info(for: name)
    }

    public func delete(name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard name != Self.stockName else { throw StoreError.readOnly(name) }
        let dir = try requireBranch(name)
        try fm.removeItem(at: dir)
        try? fm.removeItem(at: historyDirectory(for: name))
        try? fm.removeItem(at: storageDir.appendingPathComponent(name + ".json"))
        notifyChanged(name)
    }

    // MARK: Files

    /// Branch-relative paths of every (non-hidden) file, sorted.
    public func files(in branch: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Self.relativeFiles(in: directory(for: branch))
    }

    public func read(branch: String, path: String) -> String? {
        guard Self.isValidName(branch), let rel = Self.safeRelativePath(path) else { return nil }
        return try? String(contentsOf: directory(for: branch).appendingPathComponent(rel), encoding: .utf8)
    }

    public func data(branch: String, path: String) -> Data? {
        guard Self.isValidName(branch), let rel = Self.safeRelativePath(path) else { return nil }
        return try? Data(contentsOf: directory(for: branch).appendingPathComponent(rel))
    }

    public func fileExists(branch: String, path: String) -> Bool {
        guard Self.isValidName(branch), let rel = Self.safeRelativePath(path) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: directory(for: branch).appendingPathComponent(rel).path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Write and / or delete files (a `nil` value deletes). When
    /// `checkpointLabel` is given, the branch is checkpointed first so the
    /// whole batch is one undo step.
    public func write(branch: String, files: [String: String?], checkpointLabel: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard branch != Self.stockName else { throw StoreError.readOnly(branch) }
        let dir = try requireBranch(branch)
        var resolved: [(URL, String?)] = []
        for (path, content) in files {
            guard let rel = Self.safeRelativePath(path) else { throw StoreError.invalidPath(path) }
            resolved.append((dir.appendingPathComponent(rel), content))
        }
        if let checkpointLabel {
            try checkpointLocked(branch: branch, label: checkpointLabel)
        }
        for (url, content) in resolved {
            if let content {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        notifyChanged(branch)
    }

    // MARK: Checkpoints, undo, redo

    @discardableResult
    public func checkpoint(branch: String, label: String) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        return try checkpointLocked(branch: branch, label: label)
    }

    @discardableResult
    private func checkpointLocked(branch: String, label: String) throws -> Checkpoint {
        let dir = try requireBranch(branch)
        var index = readIndex(branch)
        let cp = try snapshot(dir, branch: branch, label: label, index: &index)
        index.undo.append(cp)
        // New history invalidates redo.
        for old in index.redo { try? fm.removeItem(at: snapshotDir(branch, old.id)) }
        index.redo.removeAll()
        while index.undo.count > Self.maxCheckpoints {
            let old = index.undo.removeFirst()
            try? fm.removeItem(at: snapshotDir(branch, old.id))
        }
        writeIndex(branch, index)
        return cp
    }

    public func checkpoints(branch: String) -> [Checkpoint] {
        lock.lock(); defer { lock.unlock() }
        return readIndex(branch).undo
    }

    /// Put the branch back to how it was before the most recent checkpointed
    /// change. Returns the label of what was undone.
    @discardableResult
    public func undo(branch: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard branch != Self.stockName else { throw StoreError.readOnly(branch) }
        let dir = try requireBranch(branch)
        var index = readIndex(branch)
        guard let target = index.undo.popLast() else { throw StoreError.nothingToUndo }
        let redo = try snapshot(dir, branch: branch, label: target.label, index: &index)
        index.redo.append(redo)
        try replaceTree(dir, with: snapshotDir(branch, target.id))
        try? fm.removeItem(at: snapshotDir(branch, target.id))
        writeIndex(branch, index)
        notifyChanged(branch)
        return target.label
    }

    @discardableResult
    public func redo(branch: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard branch != Self.stockName else { throw StoreError.readOnly(branch) }
        let dir = try requireBranch(branch)
        var index = readIndex(branch)
        guard let target = index.redo.popLast() else { throw StoreError.nothingToRedo }
        let undo = try snapshot(dir, branch: branch, label: target.label, index: &index)
        index.undo.append(undo)
        try replaceTree(dir, with: snapshotDir(branch, target.id))
        try? fm.removeItem(at: snapshotDir(branch, target.id))
        writeIndex(branch, index)
        notifyChanged(branch)
        return target.label
    }

    /// Record the current files as the last version known to work. The
    /// engine calls this once a branch has mounted and run without a fatal
    /// error.
    public func markGood(branch: String) {
        lock.lock(); defer { lock.unlock() }
        guard branch != Self.stockName, let dir = try? requireBranch(branch) else { return }
        let good = historyDirectory(for: branch).appendingPathComponent("good", isDirectory: true)
        if fm.fileExists(atPath: good.path), Self.treeSignature(good) == Self.treeSignature(dir) { return }
        try? fm.removeItem(at: good)
        try? copyTree(from: dir, to: good)
    }

    public func hasGoodVersion(branch: String) -> Bool {
        fm.fileExists(atPath: historyDirectory(for: branch).appendingPathComponent("good").path)
    }

    /// Replace the branch with its last known-good version. The broken
    /// version is checkpointed first, so this is itself undoable.
    public func restoreGood(branch: String) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = try requireBranch(branch)
        let good = historyDirectory(for: branch).appendingPathComponent("good", isDirectory: true)
        guard fm.fileExists(atPath: good.path) else { throw StoreError.noGoodVersion }
        try checkpointLocked(branch: branch, label: "Before restoring last working version")
        try replaceTree(dir, with: good)
        notifyChanged(branch)
    }

    private func snapshotDir(_ branch: String, _ id: Int) -> URL {
        historyDirectory(for: branch).appendingPathComponent(String(id), isDirectory: true)
    }

    private func snapshot(_ dir: URL, branch: String, label: String, index: inout HistoryIndex) throws -> Checkpoint {
        let cp = Checkpoint(id: index.next, label: label, date: Date())
        index.next += 1
        try fm.createDirectory(at: historyDirectory(for: branch), withIntermediateDirectories: true)
        try copyTree(from: dir, to: snapshotDir(branch, cp.id))
        return cp
    }

    private func readIndex(_ branch: String) -> HistoryIndex {
        let url = historyDirectory(for: branch).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(HistoryIndex.self, from: data) else {
            return HistoryIndex()
        }
        return index
    }

    private func writeIndex(_ branch: String, _ index: HistoryIndex) {
        let url = historyDirectory(for: branch).appendingPathComponent("index.json")
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: url)
    }

    // MARK: Branch storage (the JS `storage` API)

    private var storageCache: [String: [String: ShellJSON]] = [:]

    private func loadStorage(_ branch: String) -> [String: ShellJSON] {
        if let cached = storageCache[branch] { return cached }
        var out: [String: ShellJSON] = [:]
        if let text = try? String(contentsOf: storageDir.appendingPathComponent(branch + ".json"), encoding: .utf8),
           let obj = ShellJSON.parse(text)?.object {
            out = obj
        }
        storageCache[branch] = out
        return out
    }

    public func storageValue(branch: String, key: String) -> ShellJSON? {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidName(branch) else { return nil }
        return loadStorage(branch)[key]
    }

    public func setStorageValue(branch: String, key: String, value: ShellJSON?) {
        lock.lock()
        guard Self.isValidName(branch) else { lock.unlock(); return }
        var all = loadStorage(branch)
        if let value, !value.isNull { all[key] = value } else { all.removeValue(forKey: key) }
        storageCache[branch] = all
        try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? ShellJSON.object(all).jsonString().write(to: storageDir.appendingPathComponent(branch + ".json"), atomically: true, encoding: .utf8)
        lock.unlock()
        NotificationCenter.default.post(name: .shellStorageDidChange, object: self, userInfo: ["branch": branch, "key": key])
    }

    // MARK: Tree helpers

    private static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func notifyChanged(_ branch: String) {
        NotificationCenter.default.post(name: .shellBranchDidChange, object: self, userInfo: ["branch": branch])
    }

    static func relativeFiles(in dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            out.append(String(path.dropFirst(base.count).drop(while: { $0 == "/" })))
        }
        return out.sorted()
    }

    /// A cheap fingerprint of a folder's text content (paths + bytes).
    static func treeSignature(_ dir: URL) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                hash ^= UInt64(b)
                hash = hash &* 0x100000001b3
            }
        }
        for rel in relativeFiles(in: dir) {
            mix(rel.utf8)
            mix([0])
            if let data = try? Data(contentsOf: dir.appendingPathComponent(rel)) { mix(data) }
            mix([0xff])
        }
        return hash
    }

    private func copyTree(from src: URL, to dest: URL) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    private func overlayTree(from src: URL, onto dest: URL) throws {
        for rel in Self.relativeFiles(in: src) {
            let to = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: src.appendingPathComponent(rel), to: to)
        }
    }

    /// Make `dir` contain exactly what `source` contains, in place: the
    /// folder itself is kept so file watchers and open editors stay attached.
    private func replaceTree(_ dir: URL, with source: URL) throws {
        let wanted = Set(Self.relativeFiles(in: source))
        for rel in Self.relativeFiles(in: dir) where !wanted.contains(rel) {
            try? fm.removeItem(at: dir.appendingPathComponent(rel))
        }
        for rel in wanted {
            let from = source.appendingPathComponent(rel)
            let to = dir.appendingPathComponent(rel)
            if let a = try? Data(contentsOf: from), let b = try? Data(contentsOf: to), a == b { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
    }
}
