#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Import from another browser" row for a settings Form; presents `ImportSheet`.
struct ImportSettingsSection: View {
    @State private var showing = false

    var body: some View {
        Section("Import") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from another browser")
                    Text("Passwords, autofill details, history and bookmarks from Chrome, Arc, Brave, Edge or Safari.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import…") { showing = true }
            }
        }
        .sheet(isPresented: $showing) {
            ImportSheet()
        }
    }
}

extension ImportSource {
    /// Found on this Mac (vs. a file the user picked).
    var isDetected: Bool {
        switch kind {
        case .chromium, .safariLive: return true
        case .safariExport, .passwordsCSV: return false
        }
    }

    var chromiumBrowser: ChromiumBrowser? {
        if case .chromium(let b, _) = kind { return b }
        return nil
    }

    /// A file the user exported (which may hold plaintext passwords).
    var exportedFile: URL? {
        switch kind {
        case .safariExport(let url), .passwordsCSV(let url): return url
        case .chromium, .safariLive: return nil
        }
    }
}

/// Pick a source, see what it has, choose categories and a destination space, import.
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case choosing
        case importing
        case done(ImportResult)
    }

    enum Destination: Hashable {
        case existing(ID<Profile>)
        case newProfile
    }

    @State private var sources: [ImportSource] = []
    @State private var detecting = true
    @State private var selectedID: String?
    @State private var previews: [String: ImportPreview] = [:]
    /// Chromium source id → the password CSV the user exported from that
    /// browser, imported alongside it.
    @State private var passwordCSVs: [String: ImportSource] = [:]
    @State private var categories: Set<ImportCategory> = Set(ImportCategory.allCases)
    @State private var destination: Destination = .existing(.defaultProfile)
    @State private var newProfileName = ""
    @State private var phase: Phase = .choosing

    private var selected: ImportSource? { sources.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .choosing:
                HStack(spacing: 0) {
                    sourceList.frame(width: 230)
                    Divider()
                    ScrollView {
                        detail
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Divider()
                footer
            case .importing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Importing from \(selected?.title ?? "")…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let result):
                ImportResultView(result: result, sourceTitle: selected?.title ?? "", exportedFiles: usedExportedFiles) { dismiss() }
            }
        }
        .frame(width: 720, height: 520)
        .task { await detect() }
    }

    // MARK: Sources

    private var sourceList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedID }, set: { select($0) })) {
                Section("On this Mac") {
                    if detecting {
                        ProgressView().controlSize(.small)
                    } else if sources.filter(\.isDetected).isEmpty {
                        Text("No other browsers found").foregroundStyle(.secondary)
                    }
                    ForEach(sources.filter(\.isDetected)) { source in
                        ImportSourceRow(source: source).tag(source.id)
                    }
                }
                let files = sources.filter { !$0.isDetected }
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { source in
                            ImportSourceRow(source: source).tag(source.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(spacing: 6) {
                Button {
                    chooseSafariExport()
                } label: {
                    Label("Choose Safari Export…", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .help("The .zip (or its folder) from Safari's File › Export Browsing Data to File…: passwords, history and bookmarks.")
                Button {
                    choosePasswordsCSV()
                } label: {
                    Label("Choose Passwords CSV…", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .help("A passwords .csv exported from Chrome, Arc, Brave, Edge, the Passwords app, Firefox or a password manager.")
            }
            .padding(10)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let source = selected {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.title3.weight(.semibold))
                    if let subtitle = source.subtitle {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }
                if let preview = previews[source.id] {
                    if let blocker = preview.blocker {
                        ImportBlockerView(blocker: blocker, source: source, retry: { reloadPreview(source) }, chooseSafariExport: chooseSafariExport)
                    } else {
                        categoryList(source: source, preview: preview)
                        destinationPicker
                        if !preview.warnings.isEmpty {
                            ImportWarningsView(warnings: preview.warnings)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking at \(source.title)…").foregroundStyle(.secondary)
                    }
                }
            }
        } else if !detecting {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a browser to import from.").font(.title3)
                Text("Or choose a file you exported: Safari's File › Export Browsing Data to File… (.zip), or a passwords .csv from Chrome, Arc, Brave, Edge, the Passwords app or a password manager.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func categoryList(source: ImportSource, preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to import").font(.headline)
            ForEach(ImportCategory.allCases, id: \.self) { category in
                if source.available.contains(category) {
                    ImportCategoryRow(
                        category: category,
                        detail: countText(category, preview: preview),
                        isOn: categoryBinding(category),
                        enabled: (preview.count(category) ?? 0) > 0
                    )
                }
            }
            if let browser = source.chromiumBrowser {
                chromiumPasswordsRow(source: source, browser: browser, preview: preview)
            } else if case .safariLive = source.kind {
                ImportHintRow(category: .passwords, text: "Safari doesn't share passwords with other apps. In Safari, choose File › Export Browsing Data to File…, then choose that file here. It includes history and bookmarks too.") {
                    Button("Choose Safari Export…", action: chooseSafariExport)
                }
            }
        }
    }

    @ViewBuilder
    private func chromiumPasswordsRow(source: ImportSource, browser: ChromiumBrowser, preview: ImportPreview) -> some View {
        if let csv = passwordCSVs[source.id] {
            let csvPreview = previews[csv.id]
            let fileName = csv.subtitle ?? "the file"
            ImportCategoryRow(
                category: .passwords,
                detail: csvPreview.map { p in
                    p.blocker == nil ? "\(plural(p.passwords, "password")) in \(fileName)" : "Couldn't read \(fileName)"
                } ?? "Reading \(fileName)…",
                isOn: categoryBinding(.passwords),
                enabled: (csvPreview?.passwords ?? 0) > 0
            )
        } else {
            let count = preview.passwords ?? 0
            let settings = browser.passwordSettingsURL.map { "open \($0)" } ?? "open Settings › Passwords"
            let lead = count > 0 ? "\(browser.displayName) has \(count) saved password\(count == 1 ? "" : "s"). " : ""
            ImportHintRow(category: .passwords, text: "\(lead)\(browser.displayName) keeps passwords encrypted, so export them first: in \(browser.displayName), \(settings) and choose Export passwords. Then choose the .csv here.") {
                HStack {
                    Button("Choose Exported CSV…") { choosePasswordCSV(for: source) }
                    if let url = browser.passwordSettingsURL {
                        Button("Copy Settings Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private func countText(_ category: ImportCategory, preview: ImportPreview) -> String {
        switch category {
        case .passwords:
            return plural(preview.passwords, "password")
        case .autofill:
            return plural(preview.autofill, "item")
        case .history:
            let sites = plural(preview.historySites, "site")
            if let visits = preview.historyVisits, visits > 0 {
                return "\(sites), \(visits) visits in the last \(Int(ImportLimits.historyWindow / 86400)) days"
            }
            return sites
        case .bookmarks:
            let n = plural(preview.bookmarks, "bookmark")
            return (preview.bookmarks ?? 0) > 0 ? "\(n) · bookmarks are shared by all spaces" : n
        }
    }

    private func plural(_ n: Int?, _ noun: String) -> String {
        guard let n else { return "Unknown" }
        if n == 0 { return "None found" }
        return "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private func categoryBinding(_ c: ImportCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(c) },
            set: { on in if on { categories.insert(c) } else { categories.remove(c) } }
        )
    }

    private var destinationPicker: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { AutofillProfilesSnapshot(state: $0) }) { profiles in
            VStack(alignment: .leading, spacing: 8) {
                Text("Import into").font(.headline)
                Picker("Space", selection: $destination) {
                    ForEach(profiles.entries, id: \.id.raw) { entry in
                        Text(entry.displayName).tag(Destination.existing(entry.id))
                    }
                    Divider()
                    Text("New Space").tag(Destination.newProfile)
                }
                .labelsHidden()
                .fixedSize()
                if destination == .newProfile {
                    TextField("Space name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Text("A space with no favorites gets its most-visited sites as favorites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import") {
                if let selected { Task { await runImport(selected) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
        .padding(12)
    }

    /// Categories that will actually be read for `source`.
    private func effectiveCategories(_ source: ImportSource) -> Set<ImportCategory> {
        var available = source.available
        if passwordCSVs[source.id] != nil { available.insert(.passwords) }
        return categories.intersection(available)
    }

    private var canImport: Bool {
        guard let selected, let preview = previews[selected.id], preview.blocker == nil else { return false }
        return effectiveCategories(selected).contains { c in
            if c == .passwords, let csv = passwordCSVs[selected.id] {
                return (previews[csv.id]?.passwords ?? 0) > 0
            }
            return (preview.count(c) ?? 0) > 0
        }
    }

    /// Exported files that fed this import (for the "move to Trash" offer).
    private var usedExportedFiles: [URL] {
        guard let selected else { return [] }
        return [selected.exportedFile, passwordCSVs[selected.id]?.exportedFile].compactMap { $0 }
    }

    // MARK: Actions

    private func detect() async {
        destination = .existing(AutofillProfilesSnapshot(state: BrowserStore.shared.model).current)
        let found = await BrowserImporter.detectSources()
        sources = found + sources.filter { !$0.isDetected }
        detecting = false
        if selectedID == nil, let first = sources.first {
            select(first.id)
        }
    }

    private func select(_ id: String?) {
        selectedID = id
        guard let id, let source = sources.first(where: { $0.id == id }) else { return }
        // Default the new-space name to the source, unless the user typed one.
        if newProfileName.isEmpty || sources.contains(where: { $0.title == newProfileName }) {
            newProfileName = source.title
        }
        if previews[id] == nil { loadPreview(source) }
    }

    private func loadPreview(_ source: ImportSource) {
        Task {
            previews[source.id] = await BrowserImporter.preview(source)
        }
    }

    private func reloadPreview(_ source: ImportSource) {
        previews[source.id] = nil
        loadPreview(source)
    }

    /// Safari's File › Export Browsing Data to File… (.zip or unzipped folder).
    private func chooseSafariExport() {
        guard let url = pickFile(title: "Choose Safari Export", message: "Choose the .zip (or folder) Safari saved from File › Export Browsing Data to File….", types: [.zip, .folder], directories: true) else { return }
        addFileSource(BrowserImporter.exportSource(url))
    }

    private func choosePasswordsCSV() {
        guard let url = pickFile(title: "Choose Passwords CSV", message: "Choose a passwords .csv exported from a browser or password manager.", types: [.commaSeparatedText], directories: false) else { return }
        addFileSource(BrowserImporter.csvSource(url))
    }

    private func addFileSource(_ source: ImportSource) {
        if !sources.contains(where: { $0.id == source.id }) {
            sources.append(source)
        }
        select(source.id)
    }

    private func pickFile(title: String, message: String, types: [UTType], directories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Attaches the CSV a Chromium browser exported to that browser's import.
    private func choosePasswordCSV(for source: ImportSource) {
        let name = source.chromiumBrowser?.displayName ?? "the browser"
        guard let url = pickFile(title: "Choose Exported Passwords", message: "Choose the .csv file \(name) exported.", types: [.commaSeparatedText], directories: false) else { return }
        let csv = BrowserImporter.csvSource(url)
        passwordCSVs[source.id] = csv
        categories.insert(.passwords)
        reloadPreview(csv)
    }

    private func runImport(_ source: ImportSource) async {
        let cats = effectiveCategories(source)
        let target: ImportTarget
        switch destination {
        case .existing(let id): target = .existing(id)
        case .newProfile: target = .newProfile(title: newProfileName.trimmingCharacters(in: .whitespaces))
        }
        phase = .importing
        var bundle = await BrowserImporter.read(source, categories: cats)
        if cats.contains(.passwords), let csv = passwordCSVs[source.id] {
            bundle.merge(await BrowserImporter.read(csv, categories: [.passwords]))
        }
        let result = await ImportApplier.apply(bundle, categories: cats, to: target)
        phase = .done(result)
    }
}

// MARK: - Pieces

private struct ImportSourceRow: View {
    var source: ImportSource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).lineLimit(1)
                if let subtitle = source.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: source.systemImage)
        }
    }
}

private struct ImportCategoryRow: View {
    var category: ImportCategory
    var detail: String
    @Binding var isOn: Bool
    var enabled: Bool

    var body: some View {
        Toggle(isOn: Binding(get: { isOn && enabled }, set: { isOn = $0 })) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: category.systemImage).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }
}

/// A category the source can't provide directly, with what to do instead.
private struct ImportHintRow<Actions: View>: View {
    var category: ImportCategory
    var text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: category.systemImage).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                actions.controlSize(.small)
            }
        }
        .padding(.leading, 20) // line up with the checkbox rows' labels
    }
}

private struct ImportBlockerView: View {
    var blocker: ImportBlocker
    var source: ImportSource
    var retry: () -> Void
    var chooseSafariExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch blocker {
            case .needsFullDiskAccess:
                Label("Wowser needs Full Disk Access to read \(source.title)'s data.", systemImage: "lock.fill")
                    .font(.headline)
                Text("Open System Settings › Privacy & Security › Full Disk Access and turn on Wowser, then check again. You may need to relaunch Wowser.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(SafariImporter.fullDiskAccessSettingsURL)
                    }
                    Button("Check Again", action: retry)
                }
                if case .safariLive = source.kind {
                    Text("Or skip this: in Safari, choose File › Export Browsing Data to File…, and choose that file here. It includes passwords too.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    Button("Choose Safari Export…", action: chooseSafariExport)
                }
            case .unreadable(let message):
                Label("Couldn't read \(source.title).", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Try Again", action: retry)
            }
        }
    }
}

private struct ImportWarningsView: View {
    var warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ImportResultView: View {
    var result: ImportResult
    var sourceTitle: String
    var exportedFiles: [URL]
    var done: () -> Void

    @State private var trashed = false

    private struct Line: Identifiable {
        var icon: String
        var text: String
        var id: String { text }
    }

    private var lines: [Line] {
        var out: [Line] = []
        if result.passwords > 0 { out.append(Line(icon: ImportCategory.passwords.systemImage, text: "\(result.passwords) passwords")) }
        if result.autofill > 0 { out.append(Line(icon: ImportCategory.autofill.systemImage, text: "\(result.autofill) names, emails, phones & addresses")) }
        if result.historySites > 0 { out.append(Line(icon: ImportCategory.history.systemImage, text: "\(result.historySites) new sites in history")) }
        if result.bookmarks > 0 { out.append(Line(icon: ImportCategory.bookmarks.systemImage, text: "\(result.bookmarks) bookmarks")) }
        if result.favoritesAdded > 0 { out.append(Line(icon: "star", text: "\(result.favoritesAdded) favorites from your top sites")) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Imported from \(sourceTitle)", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
            if lines.isEmpty {
                Text("Nothing new to import — everything was already here.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        Label(line.text, systemImage: line.icon)
                    }
                }
            }
            if !result.warnings.isEmpty {
                ImportWarningsView(warnings: result.warnings)
            }
            if !exportedFiles.isEmpty, result.passwords > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exported password files aren't encrypted. Now that they're imported, delete them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(trashed ? "Moved to Trash" : "Move Exported File\(exportedFiles.count == 1 ? "" : "s") to Trash") {
                        NSWorkspace.shared.recycle(exportedFiles) { _, _ in }
                        trashed = true
                    }
                    .disabled(trashed)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
