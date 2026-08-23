import SwiftUI

/// Settings › Tasks: the list of scheduled agent tasks. Every row — existing
/// tasks and the trailing "New Task" row — has the same shape: a multi-line
/// instructions field with a cadence menu on the trailing edge. Existing tasks
/// additionally show a status line (last run + run-now, next run).
struct TasksSettings: View {
    @State private var newTaskText = ""
    @FocusState private var focusedTaskID: String?

    var body: some View {
        WithSnapshotMain(store: ScheduledTasksStore.shared, snapshot: { TasksSnapshot(state: $0) }) { snapshot in
            Form {
                Section {
                    ForEach(snapshot.tasks) { task in
                        TaskRow(task: task, focusedTaskID: $focusedTaskID)
                    }
                    newTaskRow
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Describe what the agent should do in plain English, then pick how often it runs. The agent works in the background; it only surfaces if it needs to show you something.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var newTaskRow: some View {
        TaskRowLayout(
            instructions: $newTaskText,
            placeholder: "New Task",
            cadence: .never,
            onCadenceChange: nil,
            status: nil,
            focusID: "new",
            focusedTaskID: $focusedTaskID
        )
        .onChange(of: newTaskText) { _, text in
            // Typing into the blank row turns it into a real task; keep the
            // caret with the text by moving focus to the new row.
            guard !text.isEmpty else { return }
            let id = ScheduledTasksStore.shared.createTask(instructions: text)
            newTaskText = ""
            DispatchQueue.main.async {
                focusedTaskID = id.raw
            }
        }
    }
}

private struct TasksSnapshot: Equatable {
    var tasks: [ScheduledTask]
    init(state: ScheduledTasksState) {
        tasks = state.tasks
    }
}

private struct TaskRow: View {
    var task: ScheduledTask
    var focusedTaskID: FocusState<String?>.Binding

    var body: some View {
        TaskRowLayout(
            instructions: Binding(
                get: { task.instructions },
                set: { ScheduledTasksStore.shared.updateInstructions(id: task.id, instructions: $0) }
            ),
            placeholder: "What should the agent do?",
            cadence: task.cadence,
            onCadenceChange: { ScheduledTasksStore.shared.setCadence(id: task.id, cadence: $0) },
            status: task,
            focusID: task.id.raw,
            focusedTaskID: focusedTaskID
        )
    }
}

/// Shared row chrome for existing + new tasks.
private struct TaskRowLayout: View {
    @Binding var instructions: String
    var placeholder: String
    var cadence: TaskCadence
    var onCadenceChange: ((TaskCadence) -> Void)?
    /// Non-nil for existing tasks: drives the status line.
    var status: ScheduledTask?
    var focusID: String
    var focusedTaskID: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                TextField(placeholder, text: $instructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused(focusedTaskID, equals: focusID)

                Picker("", selection: Binding(
                    get: { cadence },
                    set: { onCadenceChange?($0) }
                )) {
                    ForEach(TaskCadence.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(onCadenceChange == nil)
                .opacity(onCadenceChange == nil ? 0.5 : 1)
            }
            if let status {
                TaskStatusLine(task: status)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TaskStatusLine: View {
    var task: ScheduledTask

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(lastRunText)
                if task.isRunning == true {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Button {
                        ScheduledTasksStore.shared.runNow(id: task.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(task.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run now")
                }
            }
            Text("·").foregroundStyle(.tertiary)
            Text(nextRunText)
            Spacer()
            Button(role: .destructive) {
                ScheduledTasksStore.shared.deleteTask(id: task.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete task")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(task.lastRunSummary ?? "")
    }

    private var lastRunText: String {
        if task.isRunning == true { return "Running…" }
        guard let last = task.lastRunAt else { return "Never run" }
        let rel = last.formatted(.relative(presentation: .named))
        if task.lastRunWasError == true { return "Failed \(rel)" }
        return "Ran \(rel)"
    }

    private var nextRunText: String {
        guard task.cadence != .never, let next = task.nextRunAt else { return "Not scheduled" }
        if next <= Date() { return "Runs soon" }
        return "Next \(next.formatted(.relative(presentation: .named)))"
    }
}
