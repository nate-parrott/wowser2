import SwiftUI

// Settings tab listing scheduled tasks. Editing and creating share the same row UI:
// the 'New Task' row is just a blank task row that becomes a real task when filled in.
struct TasksSettings: View {
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.scheduledTasksList }) { tasks in
            Form {
                Section("Tasks") {
                    ForEach(tasks) { task in
                        ScheduledTaskRow(task: task)
                    }
                    NewTaskRow()
                }
            }
        }
    }
}

private struct ScheduledTaskRow: View {
    var task: ScheduledTask

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Describe what this task should do", text: $text, axis: .vertical)
                    .lineLimit(1...10)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: text) { newValue in
                        BrowserStore.shared.modify { state in
                            state.modifyScheduledTask(id: task.id) { $0.instructions = newValue }
                        }
                    }

                Picker("", selection: cadenceBinding) {
                    ForEach(ScheduledTask.Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            TaskStatusLine(task: task)
        }
        .padding(.vertical, 2)
        .onAppear { text = task.instructions }
        .onChange(of: task.instructions) { newValue in
            if !focused && text != newValue {
                text = newValue
            }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused {
                removeIfEmpty()
            }
        }
        .onSubmit {
            removeIfEmpty()
        }
    }

    private var cadenceBinding: Binding<ScheduledTask.Cadence> {
        Binding(
            get: { task.cadence },
            set: { newCadence in
                BrowserStore.shared.modify { state in
                    state.setCadence(newCadence, forScheduledTask: task.id)
                }
            }
        )
    }

    // Clearing a task's text deletes it (the inverse of creating one by filling in the blank row)
    private func removeIfEmpty() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BrowserStore.shared.modify { state in
                state.removeScheduledTask(id: task.id)
            }
        }
    }
}

// Bottom status line: last run time, a run-now button, and the next run time
private struct TaskStatusLine: View {
    var task: ScheduledTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Text(lastRunText(now: context.date))

                Button(action: runNow) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Run this task now")

                Text(nextRunText(now: context.date))
                    .padding(.leading, 8)

                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func lastRunText(now: Date) -> String {
        if let lastRun = task.lastRun {
            return "Last run \(relative(lastRun, now: now))"
        }
        return "Never run"
    }

    private func nextRunText(now: Date) -> String {
        if task.cadence == .never {
            return "Runs never"
        }
        if let nextRun = task.nextRun {
            return "\(task.cadence.displayName.lowercased().capitalizedFirst) · next run \(relative(nextRun, now: now))"
        }
        return task.cadence.displayName
    }

    private func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func runNow() {
        BrowserStore.shared.runScheduledTaskNow(id: task.id)
    }
}

// Blank row used to create a new task; same structure as an existing task row (minus the status line)
private struct NewTaskRow: View {
    @State private var text = ""
    @State private var cadence = ScheduledTask.Cadence.never
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("New task — describe what it should do", text: $text, axis: .vertical)
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .focused($focused)

            Picker("", selection: $cadence) {
                ForEach(ScheduledTask.Cadence.allCases, id: \.self) { cadence in
                    Text(cadence.displayName).tag(cadence)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 2)
        .onChange(of: focused) { isFocused in
            if !isFocused {
                createIfNeeded()
            }
        }
        .onSubmit {
            createIfNeeded()
        }
    }

    private func createIfNeeded() {
        let instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return }
        let cadence = self.cadence
        BrowserStore.shared.modify { state in
            var task = ScheduledTask(instructions: instructions, cadence: cadence)
            task.nextRun = cadence.interval.map { Date().addingTimeInterval($0) }
            state.addScheduledTask(task)
        }
        text = ""
        self.cadence = .never
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
