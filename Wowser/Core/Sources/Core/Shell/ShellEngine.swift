import Foundation
import JavaScriptCore
import Combine
import Observation
#if os(macOS)
import AppKit
#endif

public struct ShellErrorInfo: Equatable, Identifiable {
    public var id = UUID()
    public var message: String
    public var stack: String
    public var componentStack: [String]
    /// The window's UI could not be drawn at all (load failure, or the root
    /// component threw). Non-fatal errors are contained by an ErrorBoundary
    /// or happened in an event handler / effect.
    public var fatal: Bool
    public var date = Date()

    public var summary: String {
        var out = message
        if !componentStack.isEmpty { out += "\n  in " + componentStack.prefix(8).joined(separator: "\n  in ") }
        if !stack.isEmpty { out += "\n" + stack }
        return out
    }
}

public struct ShellLogEntry: Equatable {
    public var level: String
    public var message: String
    public var date = Date()
}

/// A command a branch registered with `commands.register`.
public struct ShellCommand: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var icon: String?
    public var hotkey: String?
    public var keywords: [String]
}

/// Runs one branch's UI code for one window.
///
/// Owns a JavaScriptCore context with the shell runtime (ShellKit/runtime)
/// loaded, feeds it slices of browser state, applies the node ops it emits to
/// `tree`, and routes native events back in. Everything here happens on the
/// main thread: the UI code shares it with the browser model, which is what
/// makes calls like `search.suggest()` synchronous.
///
/// A reload (file change, undo, `shell.reload()`) throws the context away and
/// starts a fresh one — no state survives except what the branch put in
/// `storage`.
@Observable
public final class ShellEngine {
    public let branch: String
    public let windowID: ID<WindowState>
    public let platform: String
    public let tree = ShellTree()

    /// Non-nil when the window's UI can't be shown; the root view then shows
    /// the native recovery screen.
    public private(set) var failure: ShellErrorInfo?
    /// Bumped on every (re)start; views key on it to drop stale state.
    public private(set) var generation = 0
    /// Bumped whenever the set of registered commands changes.
    public private(set) var commandsVersion = 0
    /// Point-and-comment mode: hovering highlights the element under the
    /// pointer and a click leaves a note for an agent (see ShellInspector).
    public var inspecting = false

    @ObservationIgnored public private(set) var logs: [ShellLogEntry] = []
    @ObservationIgnored public private(set) var errors: [ShellErrorInfo] = []
    @ObservationIgnored public private(set) var commands: [String: ShellCommand] = [:]
    /// Native events the branch listens for (`on("navigate", …)`).
    @ObservationIgnored public private(set) var listening = Set<String>()
    /// Per-node handlers for imperative commands (`ref.focus()`).
    @ObservationIgnored var commandHandlers: [Int: (String, ShellJSON) -> ShellJSON?] = [:]
    /// A headless load to see whether the branch works (`ShellTools.check`):
    /// calls that would change the browser are skipped.
    @ObservationIgnored var isDryRun = false
    #if os(macOS)
    @ObservationIgnored public weak var hostWindow: NSWindow?
    #endif

    // Facts about the window that live outside BrowserState.
    @ObservationIgnored public var isDark = false { didSet { if oldValue != isDark { publishSlices() } } }
    @ObservationIgnored public var isFullscreen = false { didSet { if oldValue != isFullscreen { publishSlices() } } }
    @ObservationIgnored public var isKey = true {
        didSet {
            guard oldValue != isKey else { return }
            publishSlices()
            emit("windowKey", ["isKey": .bool(isKey)])
        }
    }

    let store: ShellBranchStore
    @ObservationIgnored private var context: JSContext?
    @ObservationIgnored private var shell: JSValue?
    @ObservationIgnored private var timers: [Int: Timer] = [:]
    @ObservationIgnored private var subscriptions: [String: ShellSliceSubscription] = [:]
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var resolvedModules: [String: String] = [:]
    @ObservationIgnored private var jsDepth = 0
    @ObservationIgnored private var needsPublish = false
    @ObservationIgnored private var pendingException: String?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    @ObservationIgnored private var goodWork: DispatchWorkItem?
    @ObservationIgnored private var lastState: BrowserState?
    @ObservationIgnored private var didCommit = false
    let search = ShellSearch()
    #if canImport(Darwin)
    @ObservationIgnored private var watcher: ShellDirectoryWatcher?
    #endif

    static let rootKey = "main"
    static let maxLogs = 500

    public init(branch: String, windowID: ID<WindowState>, platform: String = ShellEngine.currentPlatform, store: ShellBranchStore = .shared) {
        self.branch = branch
        self.windowID = windowID
        self.platform = platform
        self.store = store
    }

    deinit {
        timers.values.forEach { $0.invalidate() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public static var currentPlatform: String {
        #if os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }

    public var isRunning: Bool { shell != nil }

    // MARK: Lifecycle

    /// Create the JS context, load the runtime and mount the branch.
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        teardownJS()
        failure = nil
        didCommit = false
        generation += 1

        guard let bootstrap = ShellKit.runtimeSource("bootstrap.js"), let ctx = JSContext() else {
            fail(message: "The shell runtime is missing from the app bundle.", stack: "")
            return
        }
        ctx.name = "Shell — \(branch)"
        ctx.exceptionHandler = { [weak self] _, exception in
            // An exception that escaped all the way out of a native → JS call.
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.pendingException = (exception?.toString() ?? "Unknown JavaScript error") + (stack.isEmpty || stack == "undefined" ? "" : "\n" + stack)
        }
        Self.installWatchdog(ctx)
        installHost(in: ctx)
        context = ctx

        jsDepth += 1
        ctx.evaluateScript(bootstrap, withSourceURL: URL(string: "wowser-runtime/bootstrap.js"))
        jsDepth -= 1
        if let exception = takeException() {
            fail(message: "The shell runtime failed to start: \(exception)", stack: "")
            return
        }
        shell = ctx.objectForKeyedSubscript("__shell")

        observeEnvironment()
        let entry = store.entry(branch: branch, platform: platform)
        let props: ShellJSON = ["windowId": .string(windowID.raw), "platform": .string(platform)]
        invoke("mount", [Self.rootKey, entry, props.jsonString()])
        scheduleMarkGood()
    }

    /// Tear down and start again from the files on disk.
    public func reload() {
        start()
    }

    /// Coalesce bursts of file changes (a multi-file write, an editor's
    /// save-as-rename) into one reload.
    public func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        teardownJS()
        cancellables.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        #if canImport(Darwin)
        watcher = nil
        #endif
    }

    private func teardownJS() {
        reloadWork?.cancel()
        goodWork?.cancel()
        if let shell {
            jsDepth += 1
            shell.invokeMethod("dispose", withArguments: [])
            jsDepth -= 1
            _ = takeException()
        }
        shell = nil
        context = nil
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        subscriptions.removeAll()
        resolvedModules.removeAll()
        commandHandlers.removeAll()
        listening.removeAll()
        if !commands.isEmpty {
            commands.removeAll()
            commandsVersion += 1
        }
        tree.removeAll()
    }

    private func observeEnvironment() {
        guard cancellables.isEmpty else { return }
        BrowserStore.shared.uiPublisher
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publishSlices()
        })
        observers.append(center.addObserver(forName: .shellStorageDidChange, object: store, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["branch"] as? String == self.branch else { return }
            self.publishSlices()
        })
        observers.append(center.addObserver(forName: .shellBranchDidChange, object: store, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["branch"] as? String == self.branch else { return }
            self.scheduleReload()
        })
        #if canImport(Darwin)
        // Edits made outside the app (an editor, an agent with file tools).
        watcher = ShellDirectoryWatcher(root: store.directory(for: branch)) { [weak self] in
            self?.scheduleReload()
        }
        #endif
    }

    /// Once a branch has been up for a few seconds without a fatal error,
    /// remember it as the version to fall back to.
    private func scheduleMarkGood() {
        goodWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.failure == nil, self.didCommit else { return }
            let branch = self.branch
            let store = self.store
            DispatchQueue.global(qos: .utility).async { store.markGood(branch: branch) }
        }
        goodWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Best effort: stop a script that spins forever (an accidental
    /// `while (true)`) instead of freezing the browser. Uses a JavaScriptCore
    /// entry point that isn't in the public headers, so it is looked up at
    /// runtime and simply skipped if absent.
    private static func installWatchdog(_ ctx: JSContext) {
        #if canImport(Darwin)
        typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(ctx.jsGlobalContextRef), 5.0, { _, _ in true }, nil)
        #endif
    }

    // MARK: Calling into JS

    /// Every native → JS call goes through here: it tracks nesting, surfaces
    /// stray exceptions, and pushes state the call changed back to JS before
    /// returning to the run loop.
    @discardableResult
    private func invoke(_ method: String, _ arguments: [Any]) -> JSValue? {
        guard let shell else { return nil }
        jsDepth += 1
        let result = shell.invokeMethod(method, withArguments: arguments)
        jsDepth -= 1
        if let exception = takeException() {
            record(ShellErrorInfo(message: exception, stack: "", componentStack: [], fatal: false))
        }
        if jsDepth == 0, needsPublish {
            needsPublish = false
            publishSlices()
        }
        return result
    }

    private func takeException() -> String? {
        defer { pendingException = nil }
        if let pendingException { return pendingException }
        if let exception = context?.exception {
            context?.exception = nil
            return exception.toString()
        }
        return nil
    }

    /// A native event on a node (`onPress`, `onChangeText`, …). Returns what
    /// the JS handler returned, for events that consult it (`onKey`, `onDrop`).
    @discardableResult
    public func dispatch(_ nodeID: Int, _ event: String, _ payload: ShellJSON? = nil) -> ShellJSON? {
        guard let out = invoke("dispatch", [nodeID, event, payload?.jsonString() ?? ""])?.toString(), !out.isEmpty else { return nil }
        return ShellJSON.parse(out)
    }

    /// Fire a named event at the branch. Cheap when nothing listens.
    @discardableResult
    public func emit(_ name: String, _ payload: ShellJSON) -> ShellJSON? {
        guard listening.contains(name) else { return nil }
        guard let out = invoke("emit", [name, payload.jsonString()])?.toString(), !out.isEmpty else { return nil }
        return ShellJSON.parse(out)
    }

    /// Run a command the branch registered. Returns false if it has none by that id.
    @discardableResult
    public func runCommand(_ id: String) -> Bool {
        guard commands[id] != nil else { return false }
        let wasListening = listening.contains("command")
        listening.insert("command")
        let handled = emit("command", ["id": .string(id)])
        if !wasListening { listening.remove("command") }
        return handled?.isTrue ?? false
    }

    /// Evaluate code in the UI context (the `shell_eval` tool). Returns
    /// `{"ok":true,"value":…}` or `{"ok":false,"error":…}` as JSON.
    public func evaluate(_ code: String) -> String {
        invoke("evaluate", [code])?.toString() ?? #"{"ok":false,"error":"The shell is not running."}"#
    }

    /// Where a node came from in the branch's source (file, line, owning components).
    public func describeNode(_ id: Int) -> ShellJSON? {
        guard let out = invoke("describeNode", [id])?.toString(), !out.isEmpty else { return nil }
        return ShellJSON.parse(out)
    }

    // MARK: State → JS

    private func sliceContext(_ state: BrowserState) -> ShellSliceContext {
        ShellSliceContext(state: state, windowID: windowID, branch: branch, store: store, platform: platform, isDark: isDark, isFullscreen: isFullscreen, isKey: isKey)
    }

    private func stateChanged(_ state: BrowserState) {
        let previous = lastState
        lastState = state
        publishSlices(state: state)
        if let previous, !listening.isEmpty { emitStateEvents(from: previous, to: state) }
        let search = self.search
        let windowID = self.windowID
        MainActor.assumeIsolated { search.update(state: state, windowID: windowID) }
    }

    /// Recompute every subscribed slice and hand JS the ones that changed, in
    /// a single call so one browser transaction is one render.
    func publishSlices(state: BrowserState? = nil) {
        guard shell != nil, !subscriptions.isEmpty else { return }
        if jsDepth > 0 {
            // Called from inside a JS → native call: wait until JS unwinds.
            needsPublish = true
            return
        }
        let c = sliceContext(state ?? BrowserStore.shared.model)
        var pairs: [String] = []
        for sub in subscriptions.values {
            if let json = sub.refresh(c) {
                pairs.append(sub.key)
                pairs.append(json)
            }
        }
        if !pairs.isEmpty { invoke("slices", [pairs]) }
    }

    private func emitStateEvents(from old: BrowserState, to new: BrowserState) {
        let oldWindow = old.windows[windowID]
        let newWindow = new.windows[windowID]
        if listening.contains("tabActivated"), oldWindow?.currentTab != newWindow?.currentTab {
            let now: ShellJSON = newWindow?.currentTab.map { ShellJSON.string($0.raw) } ?? .null
            let before: ShellJSON = oldWindow?.currentTab.map { ShellJSON.string($0.raw) } ?? .null
            emit("tabActivated", ["tabId": now, "previousTabId": before])
        }
        if listening.contains("spaceActivated"), let profile = newWindow?.profile, oldWindow?.profile != profile {
            emit("spaceActivated", ["spaceId": .string(profile.raw)])
        }
        if listening.contains("tabCreated") || listening.contains("tabClosed") {
            let before = Set(oldWindow?.perProfileData.values.flatMap(\.tabs) ?? [])
            let after = Set(newWindow?.perProfileData.values.flatMap(\.tabs) ?? [])
            if before != after {
                for id in after.subtracting(before) where old.tabs[id] == nil {
                    emit("tabCreated", ["tabId": .string(id.raw)])
                }
                for id in before.subtracting(after) where new.tabs[id] == nil {
                    let url: ShellJSON = (old.tabs[id]?.focusedPane?.info.url?.absoluteString).map { ShellJSON.string($0) } ?? .null
                    emit("tabClosed", ["tabId": .string(id.raw), "url": url])
                }
            }
        }
    }

    // MARK: Errors and logs

    private func fail(message: String, stack: String) {
        record(ShellErrorInfo(message: message, stack: stack, componentStack: [], fatal: true))
    }

    private func record(_ info: ShellErrorInfo) {
        errors.append(info)
        if errors.count > 100 { errors.removeFirst(errors.count - 100) }
        log("error", info.summary)
        if info.fatal { failure = info }
        NotificationCenter.default.post(name: .shellEngineDidReportError, object: self)
    }

    private func log(_ level: String, _ message: String) {
        logs.append(ShellLogEntry(level: level, message: message))
        if logs.count > Self.maxLogs { logs.removeFirst(logs.count - Self.maxLogs) }
        #if DEBUG
        print("[Shell:\(branch)] \(level): \(message)")
        #endif
    }

    /// The root error boundary rendered the native error screen.
    func rootDidFail(message: String, stack: String, componentStack: [String]) {
        guard failure == nil else { return }
        failure = ShellErrorInfo(message: message, stack: stack, componentStack: componentStack, fatal: true)
    }

    // MARK: The `__host` object

    private func installHost(in ctx: JSContext) {
        guard let host = JSValue(newObjectIn: ctx) else { return }
        host.setObject(platform, forKeyedSubscript: "platform" as NSString)
        host.setObject(windowID.raw, forKeyedSubscript: "windowId" as NSString)
        host.setObject(branch, forKeyedSubscript: "branch" as NSString)
        host.setObject(BrowserJSBridgeSource.browserObjectJS, forKeyedSubscript: "browserJS" as NSString)

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log(level, message)
        }
        host.setObject(log, forKeyedSubscript: "log" as NSString)

        let reportError: @convention(block) (String) -> Void = { [weak self] json in
            guard let self, let info = ShellJSON.parse(json) else { return }
            self.record(ShellErrorInfo(
                message: info["message"]?.string ?? "Unknown error",
                stack: info["stack"]?.string ?? "",
                componentStack: info["componentStack"]?.array?.compactMap(\.string) ?? [],
                fatal: info["fatal"]?.bool ?? false
            ))
        }
        host.setObject(reportError, forKeyedSubscript: "reportError" as NSString)

        let readBuiltin: @convention(block) (String) -> String = { name in
            ShellKit.runtimeSource("lib/\(name).js") ?? ""
        }
        host.setObject(readBuiltin, forKeyedSubscript: "readBuiltin" as NSString)

        let resolveModule: @convention(block) (String) -> String = { [weak self] base in
            self?.resolveModule(base) ?? ""
        }
        host.setObject(resolveModule, forKeyedSubscript: "resolveModule" as NSString)

        let loadModule: @convention(block) (String) -> String = { [weak self] path in
            guard let self else { return "" }
            do {
                return try self.loadModule(path)
            } catch {
                // Surface as a JS exception at the `require` call site.
                if let current = JSContext.current() {
                    current.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: current)
                }
                return ""
            }
        }
        host.setObject(loadModule, forKeyedSubscript: "loadModule" as NSString)

        let commit: @convention(block) (String) -> Void = { [weak self] json in
            self?.commit(json)
        }
        host.setObject(commit, forKeyedSubscript: "commit" as NSString)

        let command: @convention(block) (Int, String, String) -> String = { [weak self] nodeID, name, argsJSON in
            guard let self else { return "" }
            let args = ShellJSON.parse(argsJSON) ?? .null
            if name == "measure" {
                guard let f = self.tree.node(nodeID)?.frame else { return "" }
                let frame: ShellJSON = ["x": .number(Double(f.minX)), "y": .number(Double(f.minY)), "width": .number(Double(f.width)), "height": .number(Double(f.height))]
                return frame.jsonString()
            }
            return self.commandHandlers[nodeID]?(name, args)?.jsonString() ?? ""
        }
        host.setObject(command, forKeyedSubscript: "command" as NSString)

        let subscribe: @convention(block) (String) -> String = { [weak self] key in
            guard let self else { return "" }
            let sub = self.subscriptions[key] ?? ShellSliceSubscription(key: key)
            self.subscriptions[key] = sub
            _ = sub.refresh(self.sliceContext(BrowserStore.shared.model))
            return sub.json
        }
        host.setObject(subscribe, forKeyedSubscript: "subscribe" as NSString)

        let unsubscribe: @convention(block) (String) -> Void = { [weak self] key in
            self?.subscriptions.removeValue(forKey: key)
        }
        host.setObject(unsubscribe, forKeyedSubscript: "unsubscribe" as NSString)

        let call: @convention(block) (String, String) -> String = { [weak self] name, argsJSON in
            guard let self else { return "" }
            let args = argsJSON.isEmpty ? ShellJSON.null : (ShellJSON.parse(argsJSON) ?? .null)
            do {
                if self.isDryRun, !ShellActions.isSafeInDryRun(name) { return "" }
                let result = try ShellActions.perform(name, args, engine: self)
                // The action may have changed browser state; JS should see it
                // as soon as the current handler returns.
                self.needsPublish = true
                return result?.jsonString() ?? ""
            } catch {
                return "\u{1}" + ((error as? ShellCallError)?.message ?? error.localizedDescription)
            }
        }
        host.setObject(call, forKeyedSubscript: "call" as NSString)

        let callAsync: @convention(block) (Int, String, String) -> Void = { [weak self] id, name, argsJSON in
            guard let self else { return }
            let args = argsJSON.isEmpty ? ShellJSON.null : (ShellJSON.parse(argsJSON) ?? .null)
            let generation = self.generation
            Task { @MainActor [weak self] in
                guard let engine = self else { return }
                let outcome: Result<ShellJSON?, Error>
                do {
                    outcome = .success(try await ShellActions.performAsync(name, args, engine: engine))
                } catch {
                    outcome = .failure(error)
                }
                // Drop replies addressed to a context that has been reloaded.
                guard engine.generation == generation else { return }
                switch outcome {
                case .success(let value):
                    engine.invoke("resolve", [id, value?.jsonString() ?? ""])
                case .failure(let error):
                    engine.invoke("reject", [id, (error as? ShellCallError)?.message ?? error.localizedDescription])
                }
            }
        }
        host.setObject(callAsync, forKeyedSubscript: "callAsync" as NSString)

        let setTimer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeats in
            guard let self else { return }
            self.timers[id]?.invalidate()
            // Clamp so `setInterval(fn, 0)` can't starve the run loop.
            let interval = max(repeats ? 0.004 : 0, ms / 1000)
            let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
                guard let self else { return }
                if !repeats { self.timers.removeValue(forKey: id) }
                self.invoke("fireTimer", [id])
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timers[id] = timer
        }
        host.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)

        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.invalidate()
        }
        host.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)

        ctx.setObject(host, forKeyedSubscript: "__host" as NSString)
    }

    private static let moduleSuffixes = ["", ".tsx", ".ts", ".jsx", ".js", ".json", "/index.tsx", "/index.ts", "/index.jsx", "/index.js"]

    private func resolveModule(_ base: String) -> String? {
        if let hit = resolvedModules[base] { return hit }
        for suffix in Self.moduleSuffixes where store.fileExists(branch: branch, path: base + suffix) {
            resolvedModules[base] = base + suffix
            return base + suffix
        }
        return nil
    }

    private func loadModule(_ path: String) throws -> String {
        guard let source = store.read(branch: branch, path: path) else {
            throw ShellCallError("No such file: \(path)")
        }
        if path.hasSuffix(".json") { return source }
        return try ShellTranspiler.shared.transpile(source: source, path: path, dev: true)
    }

    private func commit(_ json: String) {
        guard let ops = ShellJSON.parse(json)?.array else { return }
        do {
            try tree.apply(ops)
            didCommit = true
        } catch {
            fail(message: "\(error)", stack: "")
        }
    }

    // MARK: Called by ShellActions

    func setListening(_ name: String, _ on: Bool) {
        if on { listening.insert(name) } else { listening.remove(name) }
    }

    func registerCommand(_ command: ShellCommand) {
        commands[command.id] = command
        commandsVersion += 1
    }

    func unregisterCommand(_ id: String) {
        if commands.removeValue(forKey: id) != nil { commandsVersion += 1 }
    }
}

public extension Notification.Name {
    /// Posted (object: the engine) whenever a branch reports an error.
    static let shellEngineDidReportError = Notification.Name("ShellEngineDidReportError")
}

/// An error returned to JS from a host call.
struct ShellCallError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
