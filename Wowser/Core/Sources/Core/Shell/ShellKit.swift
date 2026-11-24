import Foundation
import JavaScriptCore

/// The bundled half of the shell: the JS runtime, the TS/JSX transpiler, the
/// seed branches and the docs (`Core/Shell/ShellKit/`, copied as a resource).
public enum ShellKit {
    static let bundledDir: URL? = Bundle.module.url(forResource: "ShellKit", withExtension: nil)

    public static var bundledBranches: URL? {
        bundledDir?.appendingPathComponent("branches", isDirectory: true)
    }

    private static var sourceCache: [String: String] = [:]

    /// A file under `ShellKit/runtime/`. Main thread only (cached).
    static func runtimeSource(_ relative: String) -> String? {
        if let hit = sourceCache[relative] { return hit }
        guard let url = bundledDir?.appendingPathComponent("runtime").appendingPathComponent(relative),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        sourceCache[relative] = text
        return text
    }

    /// `wowser.d.ts` — the API reference handed to agents.
    public static var typeDefinitions: String { runtimeSource("wowser.d.ts") ?? "" }
    /// The how-to guide handed to agents alongside the type definitions.
    public static var guide: String { runtimeSource("SKILL.md") ?? "" }
}

/// Turns a branch's TS / JSX / ES-module source into CommonJS, using the
/// bundled Sucrase build in its own JS context. Main thread only.
///
/// Output is cached in memory and on disk by content, so a branch that hasn't
/// changed costs no transpilation at launch.
final class ShellTranspiler {
    static let shared = ShellTranspiler()

    struct TranspileError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var context: JSContext?
    private var function: JSValue?
    private var memory: [String: String] = [:]
    private let cacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Wowser/ShellTranspile-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    func transpile(source: String, path: String, dev: Bool) throws -> String {
        let key = "\(Self.fingerprint(path + "\u{0}" + source))-\(source.utf8.count)-\(dev ? "d" : "p")"
        if let hit = memory[key] { return hit }
        let diskURL = cacheDir?.appendingPathComponent(key + ".js")
        if let diskURL, let hit = try? String(contentsOf: diskURL, encoding: .utf8) {
            memory[key] = hit
            return hit
        }
        let fn = try ensureFunction()
        context?.exception = nil
        let out = fn.call(withArguments: [source, path, dev])
        if let exception = context?.exception {
            context?.exception = nil
            throw TranspileError(message: "\(path): \(exception.toString() ?? "syntax error")")
        }
        guard let code = out?.toString(), out?.isString == true else {
            throw TranspileError(message: "\(path): transpiler returned nothing")
        }
        memory[key] = code
        if let diskURL { try? code.write(to: diskURL, atomically: true, encoding: .utf8) }
        return code
    }

    private func ensureFunction() throws -> JSValue {
        if let function { return function }
        guard let source = ShellKit.runtimeSource("transpiler.js") else {
            throw TranspileError(message: "The transpiler is missing from the app bundle.")
        }
        guard let ctx = JSContext() else { throw TranspileError(message: "Could not create a JS context.") }
        ctx.name = "Shell transpiler"
        ctx.evaluateScript(source)
        guard let fn = ctx.objectForKeyedSubscript("__transpile"), !fn.isUndefined else {
            throw TranspileError(message: "The transpiler failed to load: \(ctx.exception?.toString() ?? "unknown error")")
        }
        ctx.exception = nil
        context = ctx
        function = fn
        return fn
    }
}

#if canImport(Darwin)
/// Watches a folder tree for changes (edits from an external editor) and
/// calls back on the main queue, debounced.
final class ShellDirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let root: URL
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
        rebuild()
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    /// One source per directory: a kqueue watch on a folder reports entries
    /// being added, removed or atomically replaced — which is how editors save.
    private func rebuild() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        var dirs = [root]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(url) }
            }
        }
        for dir in dirs.prefix(64) {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuild() // folders may have been added or replaced
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
#endif
