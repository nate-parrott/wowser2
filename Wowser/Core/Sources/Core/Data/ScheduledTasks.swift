import Foundation
#if os(macOS)
import AppKit
#endif

// A recurring task, described in plain text, performed by the browser agent
public struct ScheduledTask: Equatable, Codable, Identifiable {
    public var id: ID<ScheduledTask>
    public var instructions: String
    public var cadence: Cadence
    public var lastRun: Date?
    public var nextRun: Date?
    public var createdAt: Date

    public init(id: ID<ScheduledTask> = .assign(), instructions: String, cadence: Cadence = .never, lastRun: Date? = nil, nextRun: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.instructions = instructions
        self.cadence = cadence
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.createdAt = createdAt
    }

    public enum Cadence: String, Equatable, Codable, CaseIterable {
        case never
        case hourly
        case everyTwoHours
        case daily
        case weekly

        public var displayName: String {
            switch self {
            case .never: return "Never"
            case .hourly: return "Every Hour"
            case .everyTwoHours: return "Every 2 Hours"
            case .daily: return "Every Day"
            case .weekly: return "Every Week"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .never: return nil
            case .hourly: return 60 * 60
            case .everyTwoHours: return 2 * 60 * 60
            case .daily: return 24 * 60 * 60
            case .weekly: return 7 * 24 * 60 * 60
            }
        }
    }
}

extension BrowserState {
    public var scheduledTasksList: [ScheduledTask] {
        get { scheduledTasks ?? [] }
        set { scheduledTasks = newValue }
    }

    public mutating func addScheduledTask(_ task: ScheduledTask) {
        scheduledTasksList.append(task)
    }

    public mutating func removeScheduledTask(id: ID<ScheduledTask>) {
        scheduledTasksList.removeAll(where: { $0.id == id })
    }

    public mutating func modifyScheduledTask(id: ID<ScheduledTask>, block: (inout ScheduledTask) -> Void) {
        guard let idx = scheduledTasksList.firstIndex(where: { $0.id == id }) else { return }
        var task = scheduledTasksList[idx]
        block(&task)
        scheduledTasksList[idx] = task
    }

    // Called from the UI when the user changes a task's cadence
    public mutating func setCadence(_ cadence: ScheduledTask.Cadence, forScheduledTask id: ID<ScheduledTask>) {
        modifyScheduledTask(id: id) { task in
            task.cadence = cadence
            task.nextRun = cadence.interval.map { Date().addingTimeInterval($0) }
        }
    }

    mutating func seedDefaultScheduledTaskIfNeeded() {
        // Seed once, the first time this state has no scheduledTasks key at all.
        // (An empty-but-present list means the user deleted their tasks; don't re-seed.)
        if scheduledTasks == nil {
            scheduledTasks = [ScheduledTask(instructions: Self.defaultSeedTaskInstructions)]
        }
    }

    static let defaultSeedTaskInstructions = "Clean up my browser: organize tabs into appropriately-named groups, close duplicate tabs, and rename groups to make them more helpful."
}

extension BrowserStore {
    private static var scheduledTaskTimer: Timer?

    // Call once from setup(). Checks periodically (and on wake/foreground) for due tasks.
    public func setupScheduledTasks() {
        modify { state in
            state.seedDefaultScheduledTaskIfNeeded()
        }

        assertOnMainThread()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.runDueScheduledTasks()
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.scheduledTaskTimer = timer

        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScheduledTasksWakeOrForeground),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScheduledTasksWakeOrForeground),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif
    }

    @objc private func handleScheduledTasksWakeOrForeground() {
        runDueScheduledTasks()
    }

    private func runDueScheduledTasks() {
        assertOnMainThread()
        let now = Date()
        var dueIds = [ID<ScheduledTask>]()
        modify { state in
            for task in state.scheduledTasksList {
                guard let interval = task.cadence.interval else { continue }
                if let nextRun = task.nextRun {
                    if nextRun <= now {
                        dueIds.append(task.id)
                    }
                } else {
                    // Cadence set but no nextRun scheduled yet; schedule one out from now
                    state.modifyScheduledTask(id: task.id) { $0.nextRun = now.addingTimeInterval(interval) }
                }
            }
        }
        for id in dueIds {
            runScheduledTaskNow(id: id)
        }
    }

    // Runs a task immediately (used by the scheduler and by the run-now button in settings)
    public func runScheduledTaskNow(id: ID<ScheduledTask>) {
        assertOnMainThread()
        guard let task = model.scheduledTasksList.first(where: { $0.id == id }) else { return }
        let instructions = task.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return }

        let now = Date()
        modify { state in
            state.modifyScheduledTask(id: id) { task in
                task.lastRun = now
                task.nextRun = task.cadence.interval.map { now.addingTimeInterval($0) }
            }
        }

        let windowID = model.activeWindow?.id
        BrowserAgentManager.shared.startSession(instructions: instructions, source: .scheduledTask, windowID: windowID)
    }
}
