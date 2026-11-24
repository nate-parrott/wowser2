import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings → Customize: choose which UI branch draws the browser, try one in
/// a preview window, fork, undo, and get help from an agent.
struct ShellSettings: View {
    @State private var branches: [ShellBranchStore.BranchInfo] = []
    @State private var newName = ""
    @State private var error: String?
    private var router: ShellRouter { ShellRouter.shared }

    var body: some View {
        Form {
            Section {
                Text("Make it yours")
                    .font(.headline)
                Text("The whole browser window — sidebar, tabs, toolbar, command bar — can be drawn by a UI branch: a folder of code that you or an agent can change. The built-in UI is always there to fall back to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Browser UI", selection: Binding(
                    get: { router.activeBranch ?? "" },
                    set: { router.setActiveBranch($0.isEmpty ? nil : $0) }
                )) {
                    Text("Built-in").tag("")
                    ForEach(branches) { branch in
                        Text(branch.title).tag(branch.name)
                    }
                }
                if let crashed = router.disabledAfterCrash {
                    Label("“\(crashed)” was turned off because the browser didn’t finish loading it last time.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Ask an Agent to Change Something…") { askAgent() }
                    Button("Point at Something…") { startPointing() }
                        .disabled(router.runningEngines.isEmpty)
                        .help("Turn on a UI branch first, then click any part of the browser to leave a note about it.")
                }
            }

            Section("Branches") {
                ForEach(branches) { branch in
                    row(branch)
                }
                HStack {
                    TextField("New branch name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { create(from: ShellBranchStore.stockName) }
                    Button("Create from Built-in") { create(from: ShellBranchStore.stockName) }
                        .disabled(!ShellBranchStore.isValidName(newName))
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                Text("Branches live in \(ShellBranchStore.shared.root.appendingPathComponent("branches").path). Edit them in any editor — the browser reloads when a file changes. Agents use the `shell` tool (see Settings → MCP).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .shellBranchDidChange).receive(on: DispatchQueue.main)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private func row(_ branch: ShellBranchStore.BranchInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(branch.title).font(.body.weight(.medium))
                        if branch.isBuiltin {
                            Text("read-only").font(.caption2).foregroundStyle(.secondary)
                        }
                        if router.activeBranch == branch.name {
                            Text("in use").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                    if !branch.description.isEmpty {
                        Text(branch.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Preview") { _ = ShellTools.openPreview(branch: branch.name) }
                    .help("Open a new window drawn by this branch, next to the UI you're using.")
                Button("Show Files") { NSWorkspace.shared.open(URL(fileURLWithPath: branch.path)) }
                #endif
                Button("Duplicate") { duplicate(branch) }
                if !branch.isBuiltin {
                    Button("Undo") { perform { _ = try ShellBranchStore.shared.undo(branch: branch.name) } }
                        .disabled(!branch.canUndo)
                    Button("Redo") { perform { _ = try ShellBranchStore.shared.redo(branch: branch.name) } }
                        .disabled(!branch.canRedo)
                    Button("Delete", role: .destructive) {
                        if router.activeBranch == branch.name { router.setActiveBranch(nil) }
                        perform { try ShellBranchStore.shared.delete(name: branch.name) }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        let list = await Task.detached { () -> [ShellBranchStore.BranchInfo] in
            ShellBranchStore.shared.seedIfNeeded()
            return ShellBranchStore.shared.list()
        }.value
        branches = list
    }

    /// Run a store operation off the main thread, then refresh.
    private func perform(_ work: @escaping () throws -> Void) {
        error = nil
        Task {
            do {
                try await Task.detached { try work() }.value
            } catch {
                self.error = error.localizedDescription
            }
            await reload()
        }
    }

    private func create(from source: String) {
        let name = newName
        guard ShellBranchStore.isValidName(name) else { return }
        newName = ""
        perform { _ = try ShellBranchStore.shared.create(name: name, from: source) }
    }

    private func duplicate(_ branch: ShellBranchStore.BranchInfo) {
        let taken = Set(branches.map(\.name))
        var index = 2
        var name = branch.name + "-copy"
        while taken.contains(name) {
            name = "\(branch.name)-copy\(index)"
            index += 1
        }
        let source = branch.name
        let title = branch.title + " copy"
        perform { _ = try ShellBranchStore.shared.create(name: name, from: source, title: title) }
    }

    private func askAgent() {
        guard let windowID = BrowserStore.shared.model.activeWindow?.id else { return }
        let active = router.activeBranch ?? "none (the built-in UI)"
        AgentChatTabs.ask(query: """
        I'd like to customise this browser's own UI. Read the guide with shell "docs" first. \
        My active UI branch is: \(active). Ask me what I want to change, then make the change on a branch \
        (create one from "stock" if I don't have one), check it, and show me a preview before activating it.
        """, windowID: windowID)
    }

    private func startPointing() {
        let engines = router.runningEngines
        #if os(macOS)
        let target = engines.first(where: { $0.hostWindow?.isMainWindow == true }) ?? engines.first
        #else
        let target = engines.first
        #endif
        target?.inspecting = true
        #if os(macOS)
        target?.hostWindow?.makeKeyAndOrderFront(nil)
        #endif
    }
}
