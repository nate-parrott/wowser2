import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// App-level owner of sync: reads the settings, builds the engine with the
/// Wowser sources and a folder transport, and publishes status for the UI.
///
/// Environment overrides (used by scripts/sync_test/run_two.sh):
/// - `WOWSER_SYNC_FOLDER`: force sync on, through this local folder
/// - `WOWSER_SYNC_LATENCY`: "max" or "min-max" seconds of simulated write delay
/// - `WOWSER_SYNC_DEVICE_NAME`: name shown to other devices
public final class SyncController: ObservableObject {
    public static let shared = SyncController()

    @Published public private(set) var status = SyncStatus()
    @Published public private(set) var isRunning = false
    /// Why sync isn't running although it's on (e.g. no iCloud Drive).
    @Published public private(set) var problem: String?

    private var engine: SyncEngine?
    private var statusSub: AnyCancellable?
    private var terminateObserver: Any?
    private lazy var browserSnapshot = StoreSnapshot(BrowserStore.shared)

    private static let env = ProcessInfo.processInfo.environment
    private static var startedThisLaunch = false

    // MARK: - Settings

    public static var environmentFolder: URL? {
        env["WOWSER_SYNC_FOLDER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var isControlledByEnvironment: Bool { Self.environmentFolder != nil }

    public var isEnabled: Bool {
        isControlledByEnvironment || DefaultsKeys.syncEnabled.boolValue()
    }

    /// ~/Library/Mobile Documents/com~apple~CloudDocs, if iCloud Drive is on.
    public static var iCloudDriveRoot: URL? {
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }

    /// Dev and prod builds sync separately.
    public static var defaultFolder: URL? {
        iCloudDriveRoot?.appendingPathComponent(isProd() ? "Wowser Sync" : "Wowser Sync (Dev)", isDirectory: true)
    }

    public var folder: URL? {
        if let env = Self.environmentFolder { return env }
        let custom = DefaultsKeys.syncFolderPath.stringValue()
        return custom.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: custom, isDirectory: true)
    }

    public var usesDefaultFolder: Bool {
        !isControlledByEnvironment && DefaultsKeys.syncFolderPath.stringValue().isEmpty
    }

    static var deviceName: String {
        if let name = env["WOWSER_SYNC_DEVICE_NAME"], !name.isEmpty { return name }
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    static var stateURL: URL {
        DataStore<BrowserState>.persistentURL("Sync").deletingLastPathComponent()
            .appendingPathComponent("Sync").appendingPathComponent("engine.json")
    }

    static var simulatedLatency: ClosedRange<TimeInterval>? {
        guard let raw = env["WOWSER_SYNC_LATENCY"], !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "-").compactMap { Double($0) }
        switch parts.count {
        case 1: return 0...max(0, parts[0])
        case 2: return min(parts[0], parts[1])...max(parts[0], parts[1])
        default: return nil
        }
    }

    // MARK: - Control

    /// Called at launch.
    public func startIfEnabled() {
        if isEnabled { start() }
    }

    public func setEnabled(_ on: Bool) {
        DefaultsKeys.syncEnabled.setBool(on)
        on ? start() : stop()
    }

    /// nil = back to the default iCloud Drive folder.
    public func setFolder(_ url: URL?) {
        DefaultsKeys.syncFolderPath.setString(url?.path ?? "")
        if isRunning || isEnabled { stop(); start() }
    }

    public func syncNow() {
        engine?.scheduleTick()
    }

    public func clearLog() {
        engine?.clearDebugLog()
    }

    /// Forget this device's sync state (new device id) and re-join from the
    /// folder. Local spaces/tabs are kept and merged back in.
    public func resetLocalState() {
        let wasRunning = isRunning
        stop()
        try? FileManager.default.removeItem(at: Self.stateURL)
        BrowserStore.shared.modify { $0.sync = nil }
        if wasRunning { start() }
    }

    private func start() {
        guard engine == nil else { return }
        guard let folder else {
            problem = "iCloud Drive isn't available. Turn it on in System Settings, or choose a folder."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            problem = "Can't use \(folder.path): \(error.localizedDescription)"
            return
        }
        problem = nil

        let storage = FileSyncEngineStorage(url: Self.stateURL)
        // The transport needs the device id; make sure state exists first.
        let deviceID: String
        if let existing = storage.load() {
            deviceID = existing.deviceID
        } else {
            deviceID = UUID().uuidString
            storage.save(SyncEngineState(deviceID: deviceID))
        }
        let local = isControlledByEnvironment
        let transport = FolderSyncTransport(
            root: folder, deviceID: deviceID,
            coordinated: !local,
            pollInterval: local ? 0.25 : 5,
            writeDelay: Self.simulatedLatency)

        BrowserSyncSource.isActive = true
        let sources: [SyncSource] = [
            BrowserSyncSource(store: .shared, snapshot: browserSnapshot),
            HistorySyncSource(browser: browserSnapshot),
            AutofillSyncSource(store: .shared),
        ]
        let engine = SyncEngine(sources: sources, transport: transport, storage: storage, deviceName: Self.deviceName, throttle: local ? 0.3 : 1)
        self.engine = engine
        statusSub = engine.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.status = $0 }
        #if os(macOS)
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak engine] _ in
            engine?.flush()
        }
        #endif
        if !Self.startedThisLaunch, !DefaultsKeys.preserveWindowsAcrossRestarts.boolValue() {
            // Windows (and the tab lists in them) were thrown away at launch.
            // Don't read that as "every tab was closed": re-join instead, which
            // brings the synced tabs back into the new window.
            engine.rejoin(sourceID: "browser")
        }
        Self.startedThisLaunch = true
        engine.start()
        isRunning = true
        print("[Sync] Started: \(transport.debugDescription), device \(deviceID)")
    }

    private func stop() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        statusSub = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        BrowserSyncSource.isActive = false
        isRunning = false
        status = SyncStatus()
    }
}
