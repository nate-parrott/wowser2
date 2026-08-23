import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

// MARK: - Scheduled tasks
//
// A scheduled task is a plain-English instruction ("Every day, clean up my
// browser…") the agent runs on a fixed cadence. Tasks live in their own small
// persisted store; runs go through `AgentChatTabs.runScheduledTask`, which
// spins up a headless agent attached to the active window's omnibox.

public enum TaskCadence: String, Codable, CaseIterable, Equatable {
    case never
    case everyTwoHours
    case daily
    case weekly

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .everyTwoHours: return "Every 2 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .everyTwoHours: return 2 * 60 * 60
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

public struct ScheduledTask: Equatable, Codable, Identifiable {
    public var id: ID<ScheduledTask>
    public var instructions: String
    public var cadence: TaskCadence
    public var createdAt: Date
    /// When the scheduler should next run this task. nil when cadence is `.never`.
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastRunSummary: String?
    public var lastRunWasError: Bool?
    /// Runtime flag; cleared on load.
    public var isRunning: Bool?

    public init(id: ID<ScheduledTask> = .assign(), instructions: String, cadence: TaskCadence = .never, createdAt: Date = Date()) {
        self.id = id
        self.instructions = instructions
        self.cadence = cadence
        self.createdAt = createdAt
        self.nextRunAt = cadence.interval.map { createdAt.addingTimeInterval($0) }
    }

    /// Short label for the agent tab / session name.
    public var title: String {
        let firstLine = instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? instructions
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }

    /// Changing the cadence restarts the clock from now.
    public mutating func setCadence(_ newCadence: TaskCadence, now: Date = Date()) {
        guard newCadence != cadence else { return }
        cadence = newCadence
        nextRunAt = newCadence.interval.map { now.addingTimeInterval($0) }
    }

    public var isDue: Bool {
        guard let nextRunAt, cadence != .never, isRunning != true else { return false }
        return nextRunAt <= Date()
    }
}

public struct ScheduledTasksState: Equatable, Codable {
    public var tasks: [ScheduledTask] = []
    /// Set once the built-in starter task has been inserted.
    public var didSeedDefaults: Bool?

    public init() {}
}

public final class ScheduledTasksStore: DataStore<ScheduledTasksState> {
    public static let shared = ScheduledTasksStore(persistenceKey: "ScheduledTasks", defaultModel: .init(), queue: .main)

    public static let defaultTaskInstructions = """
    Clean up my browser: close duplicate tabs, move tabs into the spaces where they belong, \
    and rename tabs with unhelpful titles so they're easier to recognize.
    """

    public override func processModelAfterLoad(model: inout ScheduledTasksState) {
        for i in model.tasks.indices {
            model.tasks[i].isRunning = nil
        }
    }

    public override func setup() {
        super.setup()
        if model.didSeedDefaults != true {
            modify { st in
                if st.tasks.isEmpty {
                    st.tasks.append(ScheduledTask(instructions: Self.defaultTaskInstructions, cadence: .never))
                }
                st.didSeedDefaults = true
            }
        }
    }

    // MARK: - Editing

    @discardableResult
    public func createTask(instructions: String) -> ID<ScheduledTask> {
        let task = ScheduledTask(instructions: instructions)
        modify { $0.tasks.append(task) }
        return task.id
    }

    public func updateInstructions(id: ID<ScheduledTask>, instructions: String) {
        modify { st in
            guard let idx = st.tasks.firstIndex(where: { $0.id == id }) else { return }
            st.tasks[idx].instructions = instructions
        }
    }

    public func setCadence(id: ID<ScheduledTask>, cadence: TaskCadence) {
        modify { st in
            guard let idx = st.tasks.firstIndex(where: { $0.id == id }) else { return }
            st.tasks[idx].setCadence(cadence)
        }
    }

    public func deleteTask(id: ID<ScheduledTask>) {
        modify { st in st.tasks.removeAll { $0.id == id } }
    }

    // MARK: - Running

    /// Run a task right now (the ⟳ button, or the scheduler firing).
    @MainActor
    public func runNow(id: ID<ScheduledTask>) {
        guard let task = model.tasks.first(where: { $0.id == id }), task.isRunning != true else { return }
        let trimmed = task.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        guard let windowID = BrowserStore.shared.model.activeWindow?.id else { return }
        modify { st in
            guard let idx = st.tasks.firstIndex(where: { $0.id == id }) else { return }
            st.tasks[idx].isRunning = true
        }
        AgentChatTabs.runScheduledTask(task, windowID: windowID) { [weak self] result in
            self?.modify { st in
                guard let idx = st.tasks.firstIndex(where: { $0.id == id }) else { return }
                st.tasks[idx].isRunning = nil
                st.tasks[idx].lastRunAt = result.finishedAt
                st.tasks[idx].lastRunSummary = result.summary.nilIfEmpty
                st.tasks[idx].lastRunWasError = result.isError ? true : nil
                st.tasks[idx].nextRunAt = st.tasks[idx].cadence.interval.map { result.finishedAt.addingTimeInterval($0) }
            }
        }
        #endif
    }

    /// Starts the background scheduler. Checks every minute, plus on wake /
    /// app activation, and runs anything that's due.
    private var ticker: AnyCancellable?
    private var wakeObservers: [Any] = []

    @MainActor
    public func startScheduler() {
        guard ticker == nil else { return }
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
        // One at a time: if anything is already running, wait for the next tick.
        guard !model.tasks.contains(where: { $0.isRunning == true }) else { return }
        if let due = model.tasks.first(where: { $0.isDue }) {
            runNow(id: due.id)
        }
    }
}
