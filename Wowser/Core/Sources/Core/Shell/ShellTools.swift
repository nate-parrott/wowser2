import Foundation
import WebKit
#if os(macOS)
import AppKit
import ScreenCaptureKit
#endif

/// What an agent can do to the scripted UI: manage branches, edit their
/// files, load them headlessly, open a preview window, look at it, poke it.
///
/// One implementation, two front doors:
///   - the MCP tool `shell` (`{action, args}`), for Claude Code and friends;
///   - `browser.shell(action, args)` in BrowserJS, for in-browser agents.
///
/// The actions are documented for agents in ShellKit/runtime/SKILL.md.
public enum ShellTools {
    public struct Output: Sendable {
        public var json: ShellJSON
        /// A PNG, base64-encoded (the `screenshot` action).
        public var imagePNGBase64: String?
    }

    public struct ToolError: Error, LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static let actionNames = [
        "docs", "branches", "create", "delete", "files", "read", "write", "check", "undo", "redo", "history",
        "activate", "preview", "closePreview", "windows", "inspect", "describe", "logs", "eval", "event",
        "screenshot", "feedback", "inspectMode",
    ]

    private static var store: ShellBranchStore { .shared }

    @MainActor
    public static func run(action: String, args: ShellJSON) async throws -> Output {
        func require(_ key: String) throws -> String {
            guard let value = args[key]?.string, !value.isEmpty else { throw ToolError("\"\(key)\" is required for \(action)") }
            return value
        }
        func json(_ value: ShellJSON) -> Output { Output(json: value) }

        switch action {
        case "docs":
            return json(["guide": .string(ShellKit.guide), "types": .string(ShellKit.typeDefinitions)])

        case "branches":
            let router = ShellRouter.shared
            var previews: [String: ShellJSON] = [:]
            for (window, branch) in router.previewBranches { previews[window.raw] = .string(branch) }
            let list = await offMain { store.seedIfNeeded(); return store.list() }
            return json([
                "folder": .string(store.root.appendingPathComponent("branches").path),
                "active": router.activeBranch.map { ShellJSON.string($0) } ?? .null,
                "previewWindows": .object(previews),
                "branches": .array(list.map(branchJSON)),
            ])

        case "create":
            let name = try require("name")
            let from = args["from"]?.string ?? ShellBranchStore.stockName
            let title = args["title"]?.string
            let description = args["description"]?.string
            let info = try await offMainThrowing { try store.create(name: name, from: from, title: title, description: description) }
            return json(branchJSON(info))

        case "delete":
            let name = try require("name")
            if ShellRouter.shared.activeBranch == name { ShellRouter.shared.setActiveBranch(nil) }
            try await offMainThrowing { try store.delete(name: name) }
            return json(["ok": true])

        case "files":
            let branch = try require("branch")
            guard store.exists(branch) else { throw ShellBranchStore.StoreError.noSuchBranch(branch) }
            let files = await offMain { store.files(in: branch) }
            return json(.array(files.map { .string($0) }))

        case "read":
            let branch = try require("branch")
            var paths = args["paths"]?.array?.compactMap(\.string) ?? []
            if let single = args["path"]?.string { paths.append(single) }
            guard !paths.isEmpty else { throw ToolError("give \"path\" or \"paths\"") }
            let contents = await offMain { () -> [String: ShellJSON] in
                var out: [String: ShellJSON] = [:]
                for path in paths { out[path] = store.read(branch: branch, path: path).map { ShellJSON.string($0) } ?? .null }
                return out
            }
            return json(["files": .object(contents)])

        case "write":
            let branch = try require("branch")
            guard let files = args["files"]?.object, !files.isEmpty else {
                throw ToolError("\"files\" must be an object of path → content (null deletes the file)")
            }
            let summary = args["summary"]?.string?.nilIfEmpty ?? "Edit \(files.count) file\(files.count == 1 ? "" : "s")"
            var changes: [String: String?] = [:]
            for (path, content) in files {
                if content.isNull { changes[path] = .some(nil) }
                else if let text = content.string { changes[path] = text }
                else { throw ToolError("file contents must be strings (or null to delete): \(path)") }
            }
            let pending = changes
            try await offMainThrowing { try store.write(branch: branch, files: pending, checkpointLabel: summary) }
            // Editing is only half the job: say right away whether it loads.
            let result = await check(branch: branch)
            return json(["ok": true, "checkpoint": .string(summary), "check": result])

        case "check":
            return json(await check(branch: try require("branch")))

        case "undo":
            let branch = try require("branch")
            let label = try await offMainThrowing { try store.undo(branch: branch) }
            return json(["undid": .string(label), "check": await check(branch: branch)])

        case "redo":
            let branch = try require("branch")
            let label = try await offMainThrowing { try store.redo(branch: branch) }
            return json(["redid": .string(label), "check": await check(branch: branch)])

        case "history":
            let branch = try require("branch")
            let (points, info) = await offMain { (store.checkpoints(branch: branch), store.info(for: branch)) }
            let formatter = ISO8601DateFormatter()
            return json([
                "undoStack": .array(points.map { point -> ShellJSON in
                    ["id": .number(Double(point.id)), "label": .string(point.label), "date": .string(formatter.string(from: point.date))]
                }),
                "canUndo": .bool(info.canUndo),
                "canRedo": .bool(info.canRedo),
            ])

        case "activate":
            if let branch = args["branch"]?.string?.nilIfEmpty {
                guard store.exists(branch) else { throw ShellBranchStore.StoreError.noSuchBranch(branch) }
                ShellRouter.shared.setActiveBranch(branch)
                return json(["active": .string(branch)])
            }
            ShellRouter.shared.setActiveBranch(nil)
            return json(["active": .null])

        case "preview":
            let branch = try require("branch")
            guard store.exists(branch) else { throw ShellBranchStore.StoreError.noSuchBranch(branch) }
            let windowID = openPreview(branch: branch)
            // Give the window a moment to exist and the branch to mount.
            try? await Task.sleep(nanoseconds: 600_000_000)
            var out: [String: ShellJSON] = ["windowId": .string(windowID.raw), "branch": .string(branch)]
            if let engine = ShellRouter.shared.engine(for: windowID) { out["status"] = status(of: engine) }
            return json(.object(out))

        case "closePreview":
            let windowID = ID<WindowState>(raw: try require("windowId"))
            closePreview(windowID)
            return json(["ok": true])

        case "windows":
            return json(.array(ShellRouter.shared.runningEngines.map { engine -> ShellJSON in
                [
                    "windowId": .string(engine.windowID.raw),
                    "branch": .string(engine.branch),
                    "isPreview": .bool(ShellRouter.shared.isPreview(engine.windowID)),
                    "status": status(of: engine),
                ]
            }))

        case "inspect":
            let engine = try targetEngine(args)
            let depth = args["depth"]?.int ?? 40
            guard let tree = engine.tree.dump(rootKey: ShellEngine.rootKey, maxDepth: depth) else {
                return json(["status": status(of: engine), "tree": .null])
            }
            return json(["status": status(of: engine), "tree": tree])

        case "describe":
            let engine = try targetEngine(args)
            guard let id = args["nodeId"]?.int else { throw ToolError("\"nodeId\" is required") }
            return json(engine.describeNode(id) ?? .null)

        case "logs":
            let engine = try targetEngine(args)
            return json(status(of: engine, logLimit: args["limit"]?.int ?? 80))

        case "eval":
            let engine = try targetEngine(args)
            return json(ShellJSON.parse(engine.evaluate(try require("code"))) ?? .null)

        case "event":
            let engine = try targetEngine(args)
            let event = try require("event")
            var nodeID = args["nodeId"]?.int
            if nodeID == nil, let testID = args["testID"]?.string {
                nodeID = findNode(in: engine, testID: testID)
                if nodeID == nil { throw ToolError("no node with testID \"\(testID)\"") }
            }
            guard let nodeID else { throw ToolError("give \"nodeId\" or \"testID\"") }
            let result = engine.dispatch(nodeID, event, args["payload"])
            return json(["result": result ?? .null, "status": status(of: engine, logLimit: 10)])

        case "screenshot":
            #if os(macOS)
            let engine = try targetEngine(args)
            guard let window = engine.hostWindow else { throw ToolError("that window isn't on screen") }
            guard let png = await ShellScreenshot.capture(window: window) else { throw ToolError("could not capture the window") }
            return Output(json: ["mime": "image/png", "data": .string(png), "windowId": .string(engine.windowID.raw)], imagePNGBase64: png)
            #else
            throw ToolError("screenshots are only available on macOS")
            #endif

        case "feedback":
            if let id = args["resolve"]?.string {
                ShellFeedbackStore.shared.resolve(id: id)
            }
            return json(.array(ShellFeedbackStore.shared.pending.map(\.json)))

        case "inspectMode":
            let engine = try targetEngine(args)
            engine.inspecting = args["on"]?.bool ?? !engine.inspecting
            return json(["on": .bool(engine.inspecting)])

        default:
            throw ToolError("unknown action \"\(action)\". Actions: \(actionNames.joined(separator: ", "))")
        }
    }

    // MARK: Helpers

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private static func offMainThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private static func branchJSON(_ info: ShellBranchStore.BranchInfo) -> ShellJSON {
        [
            "name": .string(info.name),
            "title": .string(info.title),
            "description": .string(info.description),
            "builtin": .bool(info.isBuiltin),
            "canUndo": .bool(info.canUndo),
            "canRedo": .bool(info.canRedo),
            "path": .string(info.path),
        ]
    }

    /// The engine an action is about: `windowId` if given, else a preview
    /// window, else whichever scripted window there is.
    @MainActor
    private static func targetEngine(_ args: ShellJSON) throws -> ShellEngine {
        let router = ShellRouter.shared
        if let raw = args["windowId"]?.string {
            guard let engine = router.engine(for: ID<WindowState>(raw: raw)) else {
                throw ToolError("window \(raw) isn't running a branch. Use the \"windows\" action to list the ones that are.")
            }
            return engine
        }
        let engines = router.runningEngines
        if let preview = engines.first(where: { router.isPreview($0.windowID) }) { return preview }
        if let any = engines.first { return any }
        throw ToolError("no window is running a branch. Open one with the \"preview\" action first.")
    }

    private static func status(of engine: ShellEngine, logLimit: Int = 30) -> ShellJSON {
        var out: [String: ShellJSON] = [
            "branch": .string(engine.branch),
            "running": .bool(engine.isRunning),
            "ok": .bool(engine.failure == nil),
            "nodes": .number(Double(engine.tree.nodeCount)),
        ]
        if let failure = engine.failure { out["failure"] = .string(failure.summary) }
        let errors = engine.errors.suffix(10).map { ShellJSON.string($0.summary) }
        if !errors.isEmpty { out["errors"] = .array(Array(errors)) }
        let logs = engine.logs.suffix(logLimit).filter { $0.level != "error" }.map { ShellJSON.string("[\($0.level)] \($0.message)") }
        if !logs.isEmpty { out["logs"] = .array(Array(logs)) }
        return .object(out)
    }

    private static func findNode(in engine: ShellEngine, testID: String) -> Int? {
        guard let root = engine.tree.roots[ShellEngine.rootKey] else { return nil }
        var stack = [root]
        while let node = stack.popLast() {
            if node.string("testID") == testID { return node.id }
            stack.append(contentsOf: node.children)
        }
        return nil
    }

    /// Load a branch without showing it: mount it against the live browser
    /// state in a throwaway engine and report what happened. Calls that would
    /// change the browser are skipped while checking.
    @MainActor
    public static func check(branch: String) async -> ShellJSON {
        guard store.exists(branch) else { return ["ok": false, "errors": [.string("No branch named \"\(branch)\".")]] }
        let state = BrowserStore.shared.model
        guard let windowID = state.activeWindow?.id ?? state.windows.keys.first else {
            return ["ok": false, "errors": ["There is no browser window to check against."]]
        }
        let engine = ShellEngine(branch: branch, windowID: windowID)
        engine.isDryRun = true
        engine.start()
        // Let effects and promise callbacks run.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let result = status(of: engine)
        engine.stop()
        return result
    }

    // MARK: Preview windows

    /// Open a new browser window drawn by `branch`, next to whatever UI the
    /// user is on. It shows the same spaces and tabs.
    @MainActor
    public static func openPreview(branch: String) -> ID<WindowState> {
        var id = ID<WindowState>.assign()
        BrowserStore.shared.modify { state in
            id = state.newWindow().id
        }
        ShellRouter.shared.setPreview(branch: branch, for: id)
        return id
    }

    @MainActor
    public static func closePreview(_ windowID: ID<WindowState>) {
        #if os(macOS)
        if let window = ShellRouter.shared.engine(for: windowID)?.hostWindow {
            window.performClose(nil)
        } else {
            BrowserStore.shared.modify { $0.closeWindow(id: windowID) }
        }
        #else
        BrowserStore.shared.modify { $0.closeWindow(id: windowID) }
        #endif
        ShellRouter.shared.setPreview(branch: nil, for: windowID)
    }
}

#if os(macOS)
/// Captures a browser window as a PNG for an agent to look at.
enum ShellScreenshot {
    /// Base64 PNG at 1× (so coordinates in the image match `inspect` frames).
    @MainActor
    static func capture(window: NSWindow) async -> String? {
        var image: CGImage?
        // Pixel-true (materials, glass, web content) when the app already has
        // screen-recording permission; never prompt for it from here.
        if CGPreflightScreenCaptureAccess() {
            image = await captureWithScreenCaptureKit(window: window)
        }
        if image == nil {
            image = await captureByDrawing(window: window)
        }
        guard let image else { return nil }
        let size = window.contentView?.bounds.size ?? CGSize(width: image.width, height: image.height)
        return png1x(image, pointSize: size)?.base64EncodedString()
    }

    private static func captureWithScreenCaptureKit(window: NSWindow) async -> CGImage? {
        guard let content = try? await SCShareableContent.current,
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Fallback: draw the view hierarchy, then paint each web view's own
    /// snapshot on top (web content doesn't render through `cacheDisplay`).
    /// Blur and glass materials come out flat this way.
    @MainActor
    private static func captureByDrawing(window: NSWindow) async -> CGImage? {
        guard let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        var webViews: [WKWebView] = []
        func collect(_ v: NSView) {
            if let web = v as? WKWebView, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 1 { webViews.append(web) }
            v.subviews.forEach(collect)
        }
        collect(view)
        for web in webViews {
            let snapshot: NSImage? = await withCheckedContinuation { continuation in
                web.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
            }
            guard let snapshot else { continue }
            var frame = view.convert(web.bounds, from: web)
            if view.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            image.lockFocus()
            snapshot.draw(in: frame)
            image.unlockFocus()
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func png1x(_ image: CGImage, pointSize: CGSize) -> Data? {
        let width = max(1, Int(pointSize.width.rounded()))
        let height = max(1, Int(pointSize.height.rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
#endif

/// Notes the user left by pointing at part of the UI ("make this smaller"),
/// waiting for an agent to pick them up.
public final class ShellFeedbackStore {
    public static let shared = ShellFeedbackStore()

    public struct Note: Identifiable, Equatable {
        public var id = UUID().uuidString
        public var branch: String
        public var comment: String
        /// Where the pointed-at node comes from: host type, file, line, owners, props.
        public var node: ShellJSON
        public var frame: CGRect?
        public var date = Date()

        var json: ShellJSON {
            var out: [String: ShellJSON] = [
                "id": .string(id),
                "branch": .string(branch),
                "comment": .string(comment),
                "node": node,
            ]
            if let f = frame {
                out["frame"] = ["x": .number(Double(f.minX)), "y": .number(Double(f.minY)), "width": .number(Double(f.width)), "height": .number(Double(f.height))]
            }
            return .object(out)
        }

        /// A one-paragraph version for pasting or for an agent prompt.
        public var text: String {
            var where_ = node["type"]?.string ?? "element"
            if let file = node["file"]?.string { where_ += " at \(file):\(node["line"]?.int ?? 0)" }
            let owners = (node["owners"]?.array ?? []).compactMap { $0["component"]?.string }.prefix(4).joined(separator: " ‹ ")
            return "In UI branch \"\(branch)\", about the <\(where_)>\(owners.isEmpty ? "" : " inside \(owners)"): \(comment)"
        }
    }

    public private(set) var pending: [Note] = []

    public func add(_ note: Note) {
        pending.append(note)
        NotificationCenter.default.post(name: .shellFeedbackDidChange, object: self)
    }

    public func resolve(id: String) {
        pending.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .shellFeedbackDidChange, object: self)
    }
}

public extension Notification.Name {
    static let shellFeedbackDidChange = Notification.Name("ShellFeedbackDidChange")
}
