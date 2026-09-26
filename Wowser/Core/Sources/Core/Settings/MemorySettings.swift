import SwiftUI

/// Settings › Memory: a scope list on the left (one row per website data
/// store, with its on/off switch) and, on the right, the scope's memory
/// overview — an editable text field with a regenerate button, the last-edit
/// date and the agent's progress.
struct MemorySettings: View {
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { MemoryScopesSnapshot(scopes: MemoryStore.scopes(in: $0)) }) { snapshot in
            MemorySettingsContent(scopes: snapshot.scopes)
        }
    }
}

private struct MemoryScopesSnapshot: Equatable {
    var scopes: [MemoryStore.ScopeInfo]
}

private struct MemorySettingsContent: View {
    var scopes: [MemoryStore.ScopeInfo]
    @State private var selected: UUID?
    @ObservedObject private var store = MemoryStore.shared

    var body: some View {
        HStack(spacing: 0) {
            scopeList
                .frame(width: 200)
            Divider()
            if let selected, let scope = selectedScope(selected) {
                MemoryScopeDetail(scope: scope, info: store.overviews[selected] ?? MemoryOverviewInfo())
            } else {
                Text("Select a scope")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selected == nil { selected = scopes.first(where: { store.enabledScopesForUI.contains($0.id) })?.id ?? scopes.first?.id }
            for s in scopes where store.enabledScopesForUI.contains(s.id) { MemoryStore.shared.loadOverview(scope: s.id) }
        }
    }

    /// The snapshot's `enabled` flag is computed once per BrowserState change;
    /// read the live published set so the toggle takes effect immediately.
    private func selectedScope(_ id: UUID) -> MemoryStore.ScopeInfo? {
        guard var scope = scopes.first(where: { $0.id == id }) else { return nil }
        scope.enabled = store.enabledScopesForUI.contains(id)
        return scope
    }

    private var scopeList: some View {
        List(selection: $selected) {
            Section {
                ForEach(scopes) { scope in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.names.first ?? "Space")
                                .lineLimit(1)
                            if scope.names.count > 1 {
                                Text("+ " + scope.names.dropFirst().joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.enabledScopesForUI.contains(scope.id) },
                            set: { MemoryStore.shared.setEnabled($0, scope: scope.id) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .tag(scope.id)
                }
            } header: {
                Text("Scopes")
            } footer: {
                Text("Memory logs page visits, on-screen text, terminal output, agent chats, downloads, typed text, clicks and form submissions (never passwords or card numbers) for the spaces sharing a data store. Off until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct MemoryScopeDetail: View {
    var scope: MemoryStore.ScopeInfo
    var info: MemoryOverviewInfo

    @State private var draft = ""
    @State private var draftScope: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var eventCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !scope.enabled {
                ContentUnavailableView("Memory is off for \(scope.names.joined(separator: ", "))", systemImage: "brain", description: Text("Turn it on in the list to start logging."))
            } else {
                header
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .onChange(of: draft) { _, newValue in
                        guard info.loaded, draftScope == scope.id, newValue != info.text else { return }
                        scheduleSave(newValue)
                    }
                statusLine
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { syncDraft() }
        .onChange(of: scope.id) { _, _ in syncDraft() }
        .onChange(of: scope.enabled) { _, _ in syncDraft() }
        .onChange(of: info.text) { _, _ in
            // External update (agent, BrowserJS): reflect it unless the user is mid-edit.
            if saveTask == nil { draft = info.text }
        }
        .onChange(of: info.loaded) { _, _ in syncDraft() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory overview")
                    .font(.headline)
                Text(lastUpdatedText + (eventCount.map { " · \($0) events" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(info.status == .idle || info.status == .error ? "Regenerate" : "Regenerating…") {
                MemoryStore.shared.requestOverviewRegeneration(scope: scope.id)
            }
            .disabled(info.status == .queued || info.status == .running)
        }
    }

    private var lastUpdatedText: String {
        if let d = info.updatedAt {
            return "Last updated " + DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
        }
        return "Never updated"
    }

    @ViewBuilder private var statusLine: some View {
        switch info.status {
        case .queued, .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(info.statusDetail ?? "Working…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .error:
            Text("Failed: " + (info.statusDetail ?? "unknown error"))
                .font(.caption)
                .foregroundStyle(.red)
        case .idle:
            if let detail = info.statusDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func syncDraft() {
        draftScope = scope.id
        draft = info.text
        saveTask?.cancel()
        saveTask = nil
        if scope.enabled { refreshCount() }
    }

    private func refreshCount() {
        let id = scope.id
        Task {
            let n = try? await MemoryStore.shared.perform(scope: id) { db in
                (try db.scalar("SELECT COUNT(*) FROM events") as? Int64).map(Int.init) ?? 0
            }
            await MainActor.run { if id == scope.id { eventCount = n } }
        }
    }

    private func scheduleSave(_ text: String) {
        saveTask?.cancel()
        let id = scope.id
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            MemoryStore.shared.setOverview(scope: id, text: text)
            saveTask = nil
        }
    }
}
