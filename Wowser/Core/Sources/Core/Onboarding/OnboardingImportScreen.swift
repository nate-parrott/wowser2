#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Transfer logins and history": one row per Chromium profile found on this
/// Mac, plus a drop target for Safari's export. Pressing Import (or dropping
/// an export) asks what to import in a popover. The first import goes into
/// the current space if it's brand new; later ones each get a new space named
/// after their source (`ImportApplier` pins a few of the source's top sites
/// as favorites). Either way the window stays where it is, and a toast says
/// where the data went. The full `ImportSheet` stays one click away for the
/// fiddly cases (attaching a Chrome passwords CSV, importing into an existing
/// space).
struct OnboardingImportScreen: View {
    @Binding var state: OnboardingImportState
    var next: () -> Void

    @Environment(\.windowID) private var windowID

    @State private var showingFullImporter = false
    /// A dropped/chosen Safari export waiting for "what to import".
    @State private var pendingSafari: ImportSource?

    private var anyImported: Bool {
        state.statuses.values.contains { if case .done = $0 { return true } else { return false } }
    }

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(
                    title: "Transfer logins and history",
                    subtitle: "So you don't have to log in to everything again."
                )
                chromiumSections
                OnboardingSection(title: "Safari") {
                    OnboardingSafariDropCell(status: state.statuses[Self.safariKey]) { url in
                        let isCSV = url.pathExtension.lowercased() == "csv"
                        pendingSafari = isCSV ? BrowserImporter.csvSource(url) : BrowserImporter.exportSource(url)
                    }
                    .popover(isPresented: pendingSafariBinding, arrowEdge: .trailing) {
                        if let source = pendingSafari {
                            OnboardingImportOptions(source: source, categories: $state.categories) {
                                pendingSafari = nil
                                importSafari(source)
                            } cancel: {
                                pendingSafari = nil
                            }
                        }
                    }
                }
                Button("More Import Options…") { showingFullImporter = true }
                    .buttonStyle(.link)
            }
        }, footer: {
            if anyImported {
                Button("Continue", action: next)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip", action: next)
                    .buttonStyle(OnboardingButtonStyle(primary: false))
            }
        })
        .sheet(isPresented: $showingFullImporter) {
            ImportSheet()
        }
        .sheet(item: $state.passwordHelp) { help in
            OnboardingChromePasswordsSheet(help: help) { state.passwordHelp = nil }
        }
        .task {
            // Detect once per onboarding run, not on every remount.
            if state.sources == nil { await detect() }
        }
    }

    private var pendingSafariBinding: Binding<Bool> {
        Binding(get: { pendingSafari != nil }, set: { if !$0 { pendingSafari = nil } })
    }

    // MARK: Sections

    @ViewBuilder
    private var chromiumSections: some View {
        if let sources = state.sources {
            if sources.isEmpty {
                Text("No Chrome-family browsers found on this Mac.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browsers(sources), id: \.self) { browser in
                    OnboardingSection(title: browser.displayName) {
                        ForEach(sources.filter { $0.chromiumBrowser == browser }) { source in
                            OnboardingImportSourceCell(
                                source: source,
                                title: profileName(source, browser: browser),
                                usage: usageText(state.previews[source.id]),
                                status: state.statuses[source.id],
                                categories: $state.categories,
                                importAction: { importSource(source) }
                            )
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Helpers

    private static let safariKey = "safari-export"

    private func browsers(_ sources: [ImportSource]) -> [ChromiumBrowser] {
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

    // MARK: Actions

    private func detect() async {
        let found = await BrowserImporter.detectSources().filter { $0.chromiumBrowser != nil }
        state.sources = found
        let state = $state
        for source in found {
            Task { state.wrappedValue.previews[source.id] = await BrowserImporter.preview(source) }
        }
    }

    private func importSource(_ source: ImportSource) {
        let cats = state.categories.intersection(source.available)
        guard !cats.isEmpty else { return }
        run(source, key: source.id, title: source.title, categories: cats)
    }

    /// Safari's File › Export Browsing Data to File… (.zip or folder), or a
    /// passwords .csv.
    private func importSafari(_ source: ImportSource) {
        let cats = state.categories.intersection(source.available)
        guard !cats.isEmpty else { return }
        run(source, key: Self.safariKey, title: "Safari", categories: cats)
    }

    /// Picks the destination (decided up front, so two imports started
    /// back to back can't both claim the current space), imports, toasts.
    private func run(_ source: ImportSource, key: String, title: String, categories cats: Set<ImportCategory>) {
        let model = BrowserStore.shared.model
        let windowID = self.windowID ?? model.activeWindow?.id
        let currentProfile = windowID.flatMap { model.windows[$0]?.profile }
        let target: ImportTarget
        if !state.claimedCurrentSpace, let currentProfile, model.isFreshSpaceForImport(currentProfile) {
            state.claimedCurrentSpace = true
            target = .existing(currentProfile)
        } else {
            target = .newProfile(title: title)
        }
        state.statuses[key] = .importing
        let state = $state
        Task {
            let bundle = await BrowserImporter.read(source, categories: cats)
            let result = await ImportApplier.apply(bundle, categories: cats, to: target)
            state.wrappedValue.statuses[key] = .done(result)
            // Chromium browsers encrypt passwords, so the import couldn't
            // read them; explain how to export them instead.
            if let browser = source.chromiumBrowser {
                state.wrappedValue.passwordHelp = OnboardingPasswordHelp(browser: browser, profileID: result.profileID)
            }
            BrowserStore.shared.modify { browserState in
                if case .existing = target, let windowID {
                    browserState.addToast(message: "Imported \(title) into this space", icon: "square.and.arrow.down", in: windowID)
                } else {
                    browserState.addSpaceAddedToast(windowID: windowID)
                }
            }
        }
    }
}

/// Kept in `OnboardingModel` so imports in flight (and their results)
/// survive tab switches.
struct OnboardingImportState {
    /// nil while detecting.
    var sources: [ImportSource]?
    var previews: [String: ImportPreview] = [:]
    var statuses: [String: OnboardingImportStatus] = [:]
    /// An import has already gone into the (fresh) current space; the rest
    /// get spaces of their own.
    var claimedCurrentSpace = false
    /// Shown after a Chromium import: how to bring its passwords over too.
    var passwordHelp: OnboardingPasswordHelp?
    /// What to import; asked for when the user presses Import.
    var categories: Set<ImportCategory> = [.passwords, .autofill, .history, .bookmarks]
}

struct OnboardingPasswordHelp: Identifiable {
    var browser: ChromiumBrowser
    /// Where the browser's other data went; the passwords join it.
    var profileID: ID<Profile>
    var id: String { browser.rawValue + profileID.raw }
}

/// After a Chromium import: export the passwords from that browser as a
/// .csv, then drop it here to import into the same space.
private struct OnboardingChromePasswordsSheet: View {
    var help: OnboardingPasswordHelp
    var dismiss: () -> Void

    @State private var status: OnboardingImportStatus?
    @State private var targeted = false
    @State private var copied = false

    private var name: String { help.browser.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring your passwords too")
                .font(.title2.weight(.bold))
            Text("\(name) keeps passwords encrypted, so they weren't part of the import. Export them from \(name), then add the file here:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1) {
                    if let url = help.browser.passwordSettingsURL {
                        HStack(spacing: 8) {
                            Text("In \(name), open **\(url)**")
                            Button(copied ? "Copied" : "Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                copied = true
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Text("In \(name), open Settings › Passwords")
                    }
                }
                step(2) { Text("Click **Export passwords** (\(name) saves a .csv file)") }
                step(3) { Text("Drop that file below, or choose it") }
            }
            OnboardingSection {
                HStack(spacing: 12) {
                    OnboardingCellLabel(
                        title: "Exported passwords (.csv)",
                        subtitle: status?.doneText ?? "Delete the file afterwards; it isn't encrypted."
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
                        DispatchQueue.main.async { importCSV(url) }
                    }
                    return true
                }
            }
            HStack {
                Spacer()
                Button(isDone ? "Done" : "Not Now", action: dismiss)
                    .keyboardShortcut(isDone ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isDone: Bool {
        if case .done = status { return true }
        return false
    }

    private func step(_ n: Int, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            content()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose Exported Passwords"
        panel.message = "Choose the .csv file \(name) exported."
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCSV(url)
    }

    private func importCSV(_ url: URL) {
        status = .importing
        let source = BrowserImporter.csvSource(url)
        let profileID = help.profileID
        Task {
            let bundle = await BrowserImporter.read(source, categories: [.passwords])
            let result = await ImportApplier.apply(bundle, categories: [.passwords], to: .existing(profileID))
            status = .done(result)
        }
    }
}

/// "What to import?" — shown in a popover when the user presses Import (or
/// drops a Safari export).
private struct OnboardingImportOptions: View {
    var source: ImportSource
    @Binding var categories: Set<ImportCategory>
    var confirm: () -> Void
    var cancel: () -> Void

    private var offered: [ImportCategory] {
        [ImportCategory.passwords, .history, .bookmarks, .autofill].filter { source.available.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to import?")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(offered, id: \.self) { category in
                    Toggle(category.title, isOn: binding(category))
                        .toggleStyle(.checkbox)
                }
            }
            if source.chromiumBrowser != nil {
                // TODO: Import cookies (logged-in sessions). Nothing reads another browser's cookies yet.
                Text("Chrome keeps passwords encrypted, so they can't come along directly. We'll show you how to export them after the import.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Import", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(categories.intersection(source.available).isEmpty)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.regular)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func binding(_ c: ImportCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(c) },
            set: { on in if on { categories.insert(c) } else { categories.remove(c) } }
        )
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
    var source: ImportSource
    var title: String
    var usage: String?
    var status: OnboardingImportStatus?
    @Binding var categories: Set<ImportCategory>
    var importAction: () -> Void

    @State private var askingWhat = false

    var body: some View {
        HStack(spacing: 12) {
            OnboardingCellLabel(title: title, subtitle: status?.doneText ?? usage)
            Spacer(minLength: 8)
            OnboardingImportStatusAccessory(status: status, importAction: { askingWhat = true })
                .popover(isPresented: $askingWhat, arrowEdge: .trailing) {
                    OnboardingImportOptions(source: source, categories: $categories) {
                        askingWhat = false
                        importAction()
                    } cancel: {
                        askingWhat = false
                    }
                }
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
