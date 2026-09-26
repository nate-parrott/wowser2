import SwiftUI

/// Settings › Tasks: read-only list of agent-scheduled tasks. Tasks are
/// created and edited by agents (via `browser.tasks` / tasks.json), not here.
struct TasksSettings: View {
    var body: some View {
        WithSnapshotMain(store: ScheduledTasksStore.shared, snapshot: { TasksSnapshot(state: $0) }) { snapshot in
            Form {
                Section {
                    if snapshot.tasks.isEmpty {
                        Text("No tasks yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.tasks) { task in
                        TaskRow(task: task, isRunning: snapshot.running.contains(task.id))
                    }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Tasks are set up by the agent — ask it to do something once at a certain time, or on a schedule. Each run opens in a background tab of the current window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { ScheduledTasksStore.shared.reloadFromDisk() }
    }
}

private struct TasksSnapshot: Equatable {
    var tasks: [ScheduledTask]
    var running: Set<String>
    init(state: ScheduledTasksFile) {
        tasks = state.tasks
        running = state.runningTaskIDs
    }
}

private struct TaskRow: View {
    var task: ScheduledTask
    var isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .fontWeight(.medium)
                Spacer()
                Text(task.scheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(task.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            TaskStatusLine(task: task, isRunning: isRunning)
        }
        .padding(.vertical, 4)
        .opacity(task.isEnabled ? 1 : 0.5)
    }
}

private struct TaskStatusLine: View {
    var task: ScheduledTask
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(lastRunText)
            if isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    ScheduledTasksStore.shared.runNow(id: task.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Run now")
            }
            Text("·").foregroundStyle(.tertiary)
            Text(nextRunText)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(task.lastRunSummary ?? "")
    }

    private var lastRunText: String {
        if isRunning { return "Running…" }
        guard let last = task.lastRunAt else { return "Never run" }
        let rel = last.formatted(.relative(presentation: .named))
        if task.lastRunWasError == true { return "Failed \(rel)" }
        return "Ran \(rel)"
    }

    private var nextRunText: String {
        guard let next = task.nextFireDate() else { return "Not scheduled" }
        if next <= Date() { return "Runs soon" }
        return "Next \(next.formatted(.relative(presentation: .named)))"
    }
}
