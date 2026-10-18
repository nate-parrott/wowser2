import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings → General → Sync: on/off, folder, status, and a debug readout.
struct SyncSettingsSection: View {
    @ObservedObject private var controller = SyncController.shared
    @AppStorage(DefaultsKeys.syncEnabled.rawValue) private var syncEnabled = false
    @State private var confirmingReset = false

    var body: some View {
        Section {
            if controller.isControlledByEnvironment {
                LabeledContent("Sync") {
                    Text("On (WOWSER_SYNC_FOLDER)")
                }
            } else {
                Toggle(isOn: $syncEnabled) {
                    Text("Sync spaces, tabs, history and autofill")
                    Text("Through a folder in iCloud Drive. Passwords, cookies and memory don't sync.")
                }
                .onChange(of: syncEnabled) { _, on in controller.setEnabled(on) }
            }
            if controller.isEnabled {
                SyncFolderRow(controller: controller)
                if let problem = controller.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if controller.isRunning {
                    SyncStatusRow(status: controller.status) { controller.syncNow() }
                    if !controller.status.devices.isEmpty {
                        LabeledContent("Other devices") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(controller.status.devices) { device in
                                    HStack(spacing: 4) {
                                        Text(device.name ?? String(device.id.prefix(8)))
                                        Text(device.lastBatchAt, style: .relative).foregroundStyle(.secondary)
                                        Text("ago").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    DisclosureGroup("Debug") {
                        SyncDebugView(status: controller.status)
                        HStack {
                            Button("Clear Log") { controller.clearLog() }
                            #if os(macOS)
                            if let folder = controller.folder {
                                Button("Reveal Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            }
                            #endif
                            Spacer()
                            Button("Reset Sync State…", role: .destructive) { confirmingReset = true }
                        }
                    }
                }
            }
        } header: {
            Text("Sync")
        }
        .alert("Reset sync state?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { controller.resetLocalState() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device forgets what it has synced and joins again as a new device. Your spaces and tabs stay; anything in the sync folder is merged back in.")
        }
    }
}

private struct SyncFolderRow: View {
    @ObservedObject var controller: SyncController

    var body: some View {
        LabeledContent("Folder") {
            HStack {
                Text(controller.folder.map { displayPath($0) } ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                if !controller.isControlledByEnvironment {
                    #if os(macOS)
                    Button("Choose…") { chooseFolder() }
                    #endif
                    if !controller.usesDefaultFolder {
                        Button("Use iCloud Drive") { controller.setFolder(nil) }
                    }
                }
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        if let root = SyncController.iCloudDriveRoot, url.path.hasPrefix(root.path) {
            return "iCloud Drive" + url.path.dropFirst(root.path.count)
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Every device you sync should use the same folder (for example, one in iCloud Drive)."
        panel.directoryURL = SyncController.iCloudDriveRoot
        if panel.runModal() == .OK, let url = panel.url {
            controller.setFolder(url)
        }
    }
    #endif
}

private struct SyncStatusRow: View {
    var status: SyncStatus
    var syncNow: () -> Void

    var body: some View {
        LabeledContent {
            Button("Sync Now", action: syncNow)
        } label: {
            if let last = status.stats.lastFetchAt {
                HStack(spacing: 4) {
                    Text("Last synced")
                    Text(last, style: .relative)
                    Text("ago")
                }
            } else {
                Text("Starting…")
            }
            if let error = status.errors.first, error.at > (status.stats.lastFetchAt ?? .distantPast).addingTimeInterval(-1) {
                Text(error.message).foregroundStyle(.red)
            }
        }
    }
}

/// Everything the engine knows, for figuring out why something didn't sync.
private struct SyncDebugView: View {
    var status: SyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("This device", "\(status.deviceName) (\(status.deviceID.prefix(8)))")
                row("Transport", status.transport)
                dateRow("Last local change", status.stats.lastLocalWriteAt)
                dateRow("Last write", status.stats.lastPublishAt)
                dateRow("Last check", status.stats.lastFetchAt)
                dateRow("Last remote change", status.stats.lastRemoteChangeAt)
                row("Sent", "\(status.stats.batchesPublished) batches, \(status.stats.opsPublished) changes")
                row("Received", "\(status.stats.batchesReceived) batches, \(status.stats.opsReceived) changes")
                row("Waiting to send", "\(status.outboxCount) batches")
                row("Not applied here", "\(status.unappliedFields) fields")
                    .help("Remote values this device hasn't taken yet, e.g. navigations waiting for their tab to be reopened, or edits made here that haven't been sent.")
                row("Records", status.recordCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            .font(.caption)
            .textSelection(.enabled)

            if !status.conflicts.isEmpty {
                Text("Recent conflicts").font(.caption.bold())
                ForEach(status.conflicts.prefix(15)) { c in
                    Text("\(c.col).\(c.field) of \(c.key.prefix(8)): “\(c.winnerValue)” (\(c.winner.prefix(6))) beat “\(c.loserValue)” (\(c.loser.prefix(6))) · \(c.at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !status.errors.isEmpty {
                Text("Errors").font(.caption.bold())
                ForEach(status.errors.prefix(15)) { e in
                    Text("\(e.at.formatted(date: .omitted, time: .standard)) \(e.message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func dateRow(_ label: String, _ date: Date?) -> some View {
        row(label, date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
    }
}
