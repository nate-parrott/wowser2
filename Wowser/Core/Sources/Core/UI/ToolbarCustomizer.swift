import SwiftUI

// Customizer for the trailing toolbar region (ToolbarTrailingRegion.swift).
// `ToolbarCustomizerPopover` is shown from the toolbar (right-click) as a
// non-dismissing NSPopover with a toggle per item and drag-to-reorder.

struct ToolbarCustomizerPopover: View {
    static let width: CGFloat = 320
    static let height: CGFloat = 440

    var windowID: ID<WindowState>?
    var close: () -> Void

    private enum Mode: Equatable {
        case list
        case edit(String)
    }
    @State private var mode = Mode.list
    /// A "New Button" row is being named inline at the bottom of the list.
    @State private var naming = false

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.toolbarConfig }) { config in
            VStack(spacing: 0) {
                switch mode {
                case .edit(let id):
                    if let button = config.customButton(id: id) {
                        CustomToolbarButtonEditor(button: button, windowID: windowID, done: { mode = .list })
                    } else {
                        Color.clear.onAppear { mode = .list }
                    }
                case .list:
                    HStack {
                        Text("Customize Toolbar").font(.headline)
                        Spacer()
                        Button("Done", action: close).keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    Divider()
                    ToolbarItemList(config: config, naming: $naming, windowID: windowID, edit: { mode = .edit($0) })
                    Divider()
                    HStack {
                        Button(action: { naming = true }) {
                            Label("New Button", systemImage: "plus")
                        }
                        .disabled(naming)
                        Spacer()
                        Button("Reset") { BrowserStore.shared.modify { $0.resetToolbarToDefault() } }
                            .help("Put the built-in buttons back in their default order")
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// Every item in display order with a show/hide switch. Toggling never moves
/// a row; drag rows (native List reorder) to change the order.
private struct ToolbarItemList: View {
    var config: ToolbarConfig
    @Binding var naming: Bool
    var windowID: ID<WindowState>?
    var edit: (String) -> Void

    var body: some View {
        List {
            ForEach(config.resolvedOrder, id: \.key) { ref in
                ToolbarItemRow(ref: ref, config: config, edit: edit)
                    .listRowSeparator(.hidden)
            }
            .onMove { from, to in
                BrowserStore.shared.modify { $0.moveToolbarItems(fromOffsets: from, toOffset: to) }
            }
            if naming {
                NewToolbarButtonRow(commit: { label in
                    naming = false
                    create(label: label)
                }, cancel: { naming = false })
                .listRowSeparator(.hidden)
                .moveDisabled(true)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func create(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let button = CustomToolbarButton(label: trimmed)
        BrowserStore.shared.modify { $0.addCustomToolbarButton(button) }
        if let windowID = windowID ?? BrowserStore.shared.model.mostRecentlyActiveWindowID {
            AgentChatTabs.runToolbarButtonJob(ToolbarButtonJob(button: button, kind: .author), windowID: windowID)
        }
    }
}

private struct ToolbarItemRow: View {
    var ref: ToolbarItemRef
    var config: ToolbarConfig
    var edit: (String) -> Void
    @ObservedObject private var agentStatus = ToolbarButtonAgentStatus.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .custom(let id) = ref {
                Button(action: { edit(id) }) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Edit button")
            }
            Toggle("", isOn: Binding(
                get: { !config.hidden.contains(ref) },
                set: { on in BrowserStore.shared.modify { $0.setToolbarItemShown(ref, on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch ref {
        case .builtin(let item): return item.icon
        case .custom(let id): return config.customButton(id: id)?.icon ?? "questionmark"
        }
    }

    private var title: String {
        switch ref {
        case .builtin(let item): return item.title
        case .custom(let id): return config.customButton(id: id)?.label ?? "?"
        }
    }

    private var note: String? {
        switch ref {
        case .builtin(let item): return item.availabilityNote
        case .custom(let id):
            guard let b = config.customButton(id: id) else { return nil }
            if agentStatus.working.contains(id) { return "Coding this up…" }
            return b.bjs == nil ? "Asks agent" : nil
        }
    }
}

/// Inline naming row for a new button: type a label, press Return. An agent
/// then picks an icon and writes the button (see ToolbarButtonJob.author).
private struct NewToolbarButtonRow: View {
    var commit: (String) -> Void
    var cancel: () -> Void

    @State private var label = ""
    @State private var committed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.clear)
            Image(systemName: CustomToolbarButton.randomIcon())
                .frame(width: 22)
                .foregroundStyle(.secondary)
            TextField("What should this button do?", text: $label)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    // onSubmit can fire more than once for one Return
                    // (again on focus loss); create exactly one button.
                    guard !committed else { return }
                    committed = true
                    commit(label)
                }
                .onExitCommand(perform: cancel)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }
}

// MARK: - Editor

private struct CustomToolbarButtonEditor: View {
    var button: CustomToolbarButton
    var windowID: ID<WindowState>?
    var done: () -> Void

    @State private var label = ""
    @State private var icon = ""
    @State private var instructions = ""
    @State private var bjs = ""
    @State private var agentBacked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon.isEmpty ? "questionmark" : icon).frame(width: 22)
                TextField("Label", text: $label)
                TextField("SF Symbol", text: $icon).frame(width: 130)
            }
            Text("Purpose").font(.caption).foregroundStyle(.secondary)
            TextField("What the button is for", text: $instructions)
            Toggle("Agent-backed (an agent handles each click instead of code)", isOn: $agentBacked)
            if !agentBacked {
                Text("BrowserJS (body of an async function; `browser` and `args` in scope)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $bjs)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1)))
            }
            Spacer(minLength: 0)
            HStack {
                Button(role: .destructive, action: delete) { Text("Delete") }
                Button("Rewrite with Agent", action: rewrite)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear {
            label = button.label
            icon = button.icon
            instructions = button.instructions ?? ""
            bjs = button.bjs ?? ""
            agentBacked = button.bjs == nil
        }
    }

    private func save() {
        BrowserStore.shared.modify { st in
            st.updateCustomToolbarButton(id: button.id) { b in
                if !label.trimmingCharacters(in: .whitespaces).isEmpty { b.label = label.trimmingCharacters(in: .whitespaces) }
                if !icon.trimmingCharacters(in: .whitespaces).isEmpty { b.icon = icon.trimmingCharacters(in: .whitespaces) }
                b.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                b.bjs = agentBacked ? nil : bjs
            }
        }
        done()
    }

    private func rewrite() {
        save()
        guard let updated = BrowserStore.shared.model.toolbarConfig.customButton(id: button.id),
              let windowID = windowID ?? BrowserStore.shared.model.mostRecentlyActiveWindowID else { return }
        AgentChatTabs.runToolbarButtonJob(ToolbarButtonJob(button: updated, kind: .author), windowID: windowID)
    }

    private func delete() {
        BrowserStore.shared.modify { $0.removeCustomToolbarButton(id: button.id) }
        done()
    }
}

extension BrowserState {
    /// The window the user touched last (for actions that need *a* window).
    var mostRecentlyActiveWindowID: ID<WindowState>? {
        windows.values.max(by: { ($0.lastActive ?? .distantPast) < ($1.lastActive ?? .distantPast) })?.id
    }
}
