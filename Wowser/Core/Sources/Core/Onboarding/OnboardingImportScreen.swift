#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Transfer logins and history": one row per Chromium profile found on this
/// Mac, plus a drop target for Safari's export. Each import goes into a new
/// space named after its source (`ImportApplier` pins the source's top sites
/// as that space's favorites). The full `ImportSheet` stays one click away for
/// the fiddly cases (attaching a Chrome passwords CSV, importing into an
/// existing space).
struct OnboardingImportScreen: View {
    var next: () -> Void

    @State private var sources: [ImportSource] = []
    @State private var detecting = true
    @State private var previews: [String: ImportPreview] = [:]
    @State private var statuses: [String: OnboardingImportStatus] = [:]
    @State private var categories: Set<ImportCategory> = [.autofill, .history, .bookmarks]
    @State private var showingFullImporter = false

    private var anyImported: Bool {
        statuses.values.contains { if case .done = $0 { return true } else { return false } }
    }

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(
                    title: "Transfer logins and history",
                    subtitle: "So you don't have to log in to everything again. Each browser profile becomes its own space."
                )
                chromiumSections
                whatToImport
                OnboardingSection(title: "Safari") {
                    OnboardingSafariDropCell(status: statuses[Self.safariKey]) { url in
                        importSafari(url)
                    }
                }
                Button("More Import Options…") { showingFullImporter = true }
                    .buttonStyle(.link)
            }
        }, footer: {
            Spacer()
            if anyImported {
                Button("Done", action: next)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip", action: next)
                    .buttonStyle(OnboardingButtonStyle(primary: false))
            }
        })
        .sheet(isPresented: $showingFullImporter) {
            ImportSheet()
        }
        .task { await detect() }
    }

    // MARK: Sections

    @ViewBuilder
    private var chromiumSections: some View {
        if detecting {
            ProgressView().controlSize(.small)
        } else if sources.isEmpty {
            Text("No Chrome-family browsers found on this Mac.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(browsers, id: \.self) { browser in
                OnboardingSection(title: browser.displayName) {
                    ForEach(sources.filter { $0.chromiumBrowser == browser }) { source in
                        OnboardingImportSourceCell(
                            title: profileName(source, browser: browser),
                            usage: usageText(previews[source.id]),
                            status: statuses[source.id],
                            importAction: { importSource(source) }
                        )
                    }
                }
            }
        }
    }

    private var whatToImport: some View {
        OnboardingSection(title: "What to import") {
            ForEach([ImportCategory.history, .bookmarks, .autofill], id: \.self) { category in
                OnboardingBinaryToggleContentCell(title: category.title, isOn: categoryBinding(category))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                // TODO: Import cookies (logged-in sessions). Nothing reads another browser's cookies yet.
                Text("Passwords go into autofill. Chrome keeps passwords encrypted, so export them from Chrome and add the file under More Import Options. Safari's export includes them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onboardingCell()
        }
    }

    // MARK: Helpers

    private static let safariKey = "safari-export"

    private var browsers: [ChromiumBrowser] {
        var seen: [ChromiumBrowser] = []
        for b in sources.compactMap(\.chromiumBrowser) where !seen.contains(b) {
            seen.append(b)
        }
        return seen
    }

    /// "Google Chrome — Work" → "Work".
    private func profileName(_ source: ImportSource, browser: ChromiumBrowser) -> String {
        let prefix = browser.displayName + " — "
        if source.title.hasPrefix(prefix) {
            return String(source.title.dropFirst(prefix.count))
        }
        return source.subtitle ?? "Default profile"
    }

    private func usageText(_ preview: ImportPreview?) -> String? {
        guard let preview else { return nil }
        if let visits = preview.historyVisits, visits > 0 {
            return "\(visits.formatted()) visits in the last \(Int(ImportLimits.historyWindow / 86400)) days"
        }
        if let sites = preview.historySites, sites > 0 {
            return "\(sites.formatted()) sites"
        }
        return "No recent history"
    }

    private func categoryBinding(_ c: ImportCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(c) },
            set: { on in if on { categories.insert(c) } else { categories.remove(c) } }
        )
    }

    // MARK: Actions

    private func detect() async {
        let found = await BrowserImporter.detectSources().filter { $0.chromiumBrowser != nil }
        sources = found
        detecting = false
        for source in found {
            Task { previews[source.id] = await BrowserImporter.preview(source) }
        }
    }

    private func importSource(_ source: ImportSource) {
        let cats = categories.intersection(source.available)
        statuses[source.id] = .importing
        Task {
            let bundle = await BrowserImporter.read(source, categories: cats)
            let result = await ImportApplier.apply(bundle, categories: cats, to: .newProfile(title: source.title))
            statuses[source.id] = .done(result)
        }
    }

    /// Safari's File › Export Browsing Data to File… (.zip or folder), or a
    /// passwords .csv.
    private func importSafari(_ url: URL) {
        let isCSV = url.pathExtension.lowercased() == "csv"
        let source = isCSV ? BrowserImporter.csvSource(url) : BrowserImporter.exportSource(url)
        let cats = categories.union([.passwords]).intersection(source.available)
        statuses[Self.safariKey] = .importing
        Task {
            let bundle = await BrowserImporter.read(source, categories: cats)
            let result = await ImportApplier.apply(bundle, categories: cats, to: .newProfile(title: "Safari"))
            statuses[Self.safariKey] = .done(result)
        }
    }
}

enum OnboardingImportStatus: Equatable {
    case importing
    case done(ImportResult)

    var doneText: String? {
        guard case .done(let r) = self else { return nil }
        var parts: [String] = []
        if r.historySites > 0 { parts.append("\(r.historySites) sites") }
        if r.bookmarks > 0 { parts.append("\(r.bookmarks) bookmarks") }
        if r.passwords > 0 { parts.append("\(r.passwords) passwords") }
        if r.autofill > 0 { parts.append("\(r.autofill) autofill items") }
        return parts.isEmpty ? "Imported" : "Imported " + parts.joined(separator: ", ")
    }
}

private struct OnboardingImportSourceCell: View {
    var title: String
    var usage: String?
    var status: OnboardingImportStatus?
    var importAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            OnboardingCellLabel(title: title, subtitle: status?.doneText ?? usage)
            Spacer(minLength: 8)
            OnboardingImportStatusAccessory(status: status, importAction: importAction)
        }
        .onboardingCell()
    }
}

private struct OnboardingImportStatusAccessory: View {
    var status: OnboardingImportStatus?
    var importAction: () -> Void

    var body: some View {
        switch status {
        case .none:
            Button("Import", action: importAction)
        case .importing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

/// Drop (or choose) the file Safari exports via File › Export Browsing Data
/// to File…, or any passwords .csv.
private struct OnboardingSafariDropCell: View {
    var status: OnboardingImportStatus?
    var importFile: (URL) -> Void

    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.title3)
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            OnboardingCellLabel(
                title: "Drop your exported passwords here",
                subtitle: status?.doneText ?? "In Safari, choose File › Export Browsing Data to File…, then drop the .zip here. A passwords .csv works too."
            )
            Spacer(minLength: 8)
            if status == nil {
                Button("Choose File…", action: choose)
            } else {
                OnboardingImportStatusAccessory(status: status, importAction: {})
            }
        }
        .onboardingCell()
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard status == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { importFile(url) }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose Safari Export"
        panel.message = "Choose the .zip (or folder) Safari saved from File › Export Browsing Data to File…, or a passwords .csv."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }
}
#endif
