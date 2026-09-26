import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

// MARK: - Scheduled tasks
//
// Agent-authored tasks that run once (explicit fire dates) or on a cadence
// (a recurrence rule). The source of truth is a JSON file that agents edit
// with `browser.fs` — see `ScheduledTasksStore.fileURL` and the `tasks`
// section of BrowserJS.d.ts for the schema. The browser only writes back
// run bookkeeping (lastRun*, consumed fire dates). Each task also gets a
// private data file (`ScheduledTasksStore.dataFileURL`) that the run agent
// reads at the start and writes at the end.
//
// Runs open a real background tab in the active window; the previous run's
// tab is closed when a new run starts so they never pile up.

public struct TaskRecurrence: Equatable, Codable {
    public enum Kind: String, Codable {
        case interval   // every `seconds`
        case daily      // every day at hour:minute
        case weekly     // every week on `weekday` (1 = Sunday … 7 = Saturday) at hour:minute
    }
    public var kind: Kind
    public var seconds: Double?
    public var hour: Int?
    public var minute: Int?
    public var weekday: Int?

    /// First occurrence strictly after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .interval:
            guard let seconds, seconds >= 60 else { return nil }
            return date.addingTimeInterval(seconds)
        case .daily:
            var comps = DateComponents()
            comps.hour = hour ?? 9
            comps.minute = minute ?? 0
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
        case .weekly:
            var comps = DateComponents()
            comps.weekday = weekday ?? 2
            comps.hour = hour ?? 9
            comps.minute = minute ?? 0
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
        }
    }

    public var displayName: String {
        let time = String(format: "%d:%02d", hour ?? 9, minute ?? 0)
        switch kind {
        case .interval:
            let s = seconds ?? 0
            if s >= 86400, s.truncatingRemainder(dividingBy: 86400) == 0 { return "Every \(Int(s / 86400))d" }
            if s >= 3600, s.truncatingRemainder(dividingBy: 3600) == 0 { return "Every \(Int(s / 3600))h" }
            return "Every \(Int(s / 60))m"
        case .daily:
            return "Daily at \(time)"
        case .weekly:
            let names = Calendar.current.weekdaySymbols
            let idx = max(1, min(7, weekday ?? 2)) - 1
            return "\(names[idx])s at \(time)"
        }
    }
}

public struct ScheduledTask: Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var prompt: String
    /// One-off firing times (ISO 8601). Consumed by the browser once fired.
    public var fireDates: [Date]?
    public var recurrence: TaskRecurrence?
    public var enabled: Bool?
    public var createdAt: Date?

    // Written by the browser after each run.
    public var lastRunAt: Date?
    public var lastRunSummary: String?
    public var lastRunWasError: Bool?
    /// Agent-chat key of the most recent run; its tab is closed on the next run.
    public var lastRunAgentKey: String?

    public var isEnabled: Bool { enabled ?? true }

    /// Earliest pending firing: the soonest fire date, or the next recurrence
    /// after the last run (or creation).
    public func nextFireDate(now: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        var candidates: [Date] = fireDates ?? []
        if let recurrence, let n = recurrence.next(after: lastRunAt ?? createdAt ?? now) {
            candidates.append(n)
        }
        return candidates.min()
    }

    public func isDue(now: Date = Date()) -> Bool {
        guard let next = nextFireDate(now: now) else { return false }
        return next <= now
    }

    public var scheduleDescription: String {
        var parts: [String] = []
        if let recurrence { parts.append(recurrence.displayName) }
        let pending = (fireDates ?? []).filter { $0 > Date() }.sorted()
        if let first = pending.first {
            parts.append("Once " + first.formatted(.relative(presentation: .named)))
            if pending.count > 1 { parts[parts.count - 1] += " (+\(pending.count - 1) more)" }
        }
        if parts.isEmpty { parts.append(isEnabled ? "No schedule" : "Disabled") }
        return parts.joined(separator: " · ")
    }
}

public struct ScheduledTasksFile: Equatable, Codable {
    public var tasks: [ScheduledTask] = []
    /// Runtime only (not written to disk): tasks with a run in progress.
    public var runningTaskIDs: Set<String> = []
    public init() {}

    enum CodingKeys: String, CodingKey { case tasks }
}

/// In-memory mirror of `tasks.json`; reloads when the file changes on disk.
public final class ScheduledTasksStore: DataStore<ScheduledTasksFile> {
    public static let shared = ScheduledTasksStore(persistenceKey: nil, defaultModel: .init(), queue: .main)

    public static let directoryURL: URL = DataStore<ScheduledTasksFile>.persistentURL("ScheduledTasks").deletingPathExtension()
    public static let fileURL: URL = directoryURL.appendingPathComponent("tasks.json")
    public static let dataDirectoryURL: URL = directoryURL.appendingPathComponent("data")

    public static func dataFileURL(taskID: String) -> URL {
        let safe = taskID.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return dataDirectoryURL.appendingPathComponent(safe + ".json")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Agents write dates with `toISOString()` (fractional seconds) or by
        // hand (none); accept both.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(raw)"))
        }
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private var ticker: AnyCancellable?
    private var wakeObservers: [Any] = []
    private var dirWatcher: DispatchSourceFileSystemObject?

    // MARK: - Disk

    /// Reads tasks.json (creating an empty one on first launch) into `model`.
    public func reloadFromDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dataDirectoryURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            if !fm.fileExists(atPath: Self.fileURL.path) { writeToDisk(ScheduledTasksFile()) }
            return
        }
        do {
            var file = try Self.decoder.decode(ScheduledTasksFile.self, from: data)
            // Stamp createdAt on new tasks so recurrences have a reference point.
            var changed = false
            for i in file.tasks.indices where file.tasks[i].createdAt == nil {
                file.tasks[i].createdAt = Date()
                changed = true
            }
            if changed { writeToDisk(file) }
            if file.tasks != model.tasks { modify { $0.tasks = file.tasks } }
        } catch {
            print("[ScheduledTasks] tasks.json failed to parse: \(error)")
        }
    }

    private func writeToDisk(_ file: ScheduledTasksFile) {
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            try Self.encoder.encode(file).write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[ScheduledTasks] failed to write tasks.json: \(error)")
        }
    }

    /// Browser-side bookkeeping edits: apply to the latest on-disk file, not
    /// our possibly stale mirror, so we never clobber an agent's edit.
    private func updateTask(id: String, _ block: (inout ScheduledTask) -> Void) {
        reloadFromDisk()
        var file = ScheduledTasksFile()
        file.tasks = model.tasks
        guard let idx = file.tasks.firstIndex(where: { $0.id == id }) else { return }
        block(&file.tasks[idx])
        writeToDisk(file)
        modify { $0.tasks = file.tasks }
    }

    private func startWatchingDirectory() {
        guard dirWatcher == nil else { return }
        let fd = open(Self.directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.reloadFromDisk() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatcher = src
    }

    // MARK: - Running

    /// Run a task right now (the ↻ button, or the scheduler firing).
    @MainActor
    public func runNow(id: String) {
        guard let task = model.tasks.first(where: { $0.id == id }), !model.runningTaskIDs.contains(id) else { return }
        guard !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        #if os(macOS)
        guard let windowID = BrowserStore.shared.model.activeWindow?.id else { return }
        modify { $0.runningTaskIDs.insert(id) }

        // Previous run's tab goes away so runs don't pile up.
        if let oldKey = task.lastRunAgentKey {
            AgentChatTabs.close(key: oldKey)
        }
        let startedAt = Date()
        let key = AgentChatTabs.startScheduledTask(task, windowID: windowID) { [weak self] result in
            guard let self else { return }
            self.modify { $0.runningTaskIDs.remove(id) }
            self.updateTask(id: id) { t in
                t.lastRunAt = result.finishedAt
                t.lastRunSummary = result.summary.nilIfEmpty
                t.lastRunWasError = result.isError ? true : nil
            }
        }
        updateTask(id: id) { t in
            t.lastRunAgentKey = key
            // Consume the one-off dates this run covers.
            t.fireDates = t.fireDates?.filter { $0 > startedAt }
            // Anchor recurrence at the start so a long run doesn't drift it.
            t.lastRunAt = startedAt
        }
        BrowserStore.shared.modify { $0.addToast(message: "Running task: \(task.title)", icon: "clock.arrow.circlepath", in: windowID) }
        #endif
    }

    public func isRunning(id: String) -> Bool { model.runningTaskIDs.contains(id) }

    /// Starts the background scheduler. Checks every minute, plus on wake /
    /// app activation, and runs anything that's due.
    @MainActor
    public func startScheduler() {
        guard ticker == nil else { return }
        reloadFromDisk()
        startWatchingDirectory()
        ticker = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.runDueTasks() }
            }
        #if os(macOS)
        for name in [NSWorkspace.didWakeNotification, NSApplication.didBecomeActiveNotification] {
            wakeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runDueTasks() }
            })
        }
        #endif
        runDueTasks()
    }

    @MainActor
    private func runDueTasks() {
        reloadFromDisk()
        // One at a time: if anything is already running, wait for the next tick.
        guard model.runningTaskIDs.isEmpty else { return }
        if let due = model.tasks.first(where: { $0.isDue() }) {
            runNow(id: due.id)
        }
    }
}
