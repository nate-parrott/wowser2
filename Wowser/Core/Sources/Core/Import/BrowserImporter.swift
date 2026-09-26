import Foundation

/// Front door for the import sheet: finds sources, previews them and reads
/// them. Everything here does file I/O, so it runs off the main thread.
///
/// Passwords only ever come from files the user exported themselves (a CSV or
/// Safari's export). We never read another browser's keychain entries or
/// decrypt its password store.
public enum BrowserImporter {
    /// Chromium profiles on this Mac, then Safari.
    public static func detectSources() async -> [ImportSource] {
        await Task.detached(priority: .userInitiated) {
            var sources = ChromiumImporter.detectSources()
            if FileManager.default.fileExists(atPath: SafariImporter.safariDir.path) {
                sources.append(SafariImporter.liveSource)
            }
            return sources
        }.value
    }

    public static func csvSource(_ url: URL) -> ImportSource {
        ImportSource(kind: .passwordsCSV(url), title: "Passwords file", subtitle: url.lastPathComponent, systemImage: "doc.text", available: [.passwords])
    }

    public static func exportSource(_ url: URL) -> ImportSource {
        SafariImporter.exportSource(url)
    }

    public static func preview(_ source: ImportSource) async -> ImportPreview {
        await Task.detached(priority: .userInitiated) {
            switch source.kind {
            case .chromium(_, let dir):
                return ChromiumImporter.preview(profileDir: dir)
            case .safariLive:
                return SafariImporter.previewLive()
            case .safariExport(let url):
                return SafariImporter.previewExport(url)
            case .passwordsCSV(let url):
                var p = ImportPreview()
                do { p.passwords = try PasswordsCSV.read(url).count }
                catch ImportError.needsFullDiskAccess { p.blocker = .needsFullDiskAccess }
                catch { p.blocker = .unreadable(error.localizedDescription) }
                return p
            }
        }.value
    }

    /// Reads the chosen categories.
    public static func read(_ source: ImportSource, categories: Set<ImportCategory>) async -> ImportBundle {
        await Task.detached(priority: .userInitiated) {
            switch source.kind {
            case .chromium(let browser, let dir):
                return ChromiumImporter.read(browser: browser, profileDir: dir, categories: categories)
            case .safariLive:
                return SafariImporter.readLive(categories: categories)
            case .safariExport(let url):
                do { return try SafariImporter.readExport(url, categories: categories) }
                catch { return ImportBundle(warnings: [error.localizedDescription]) }
            case .passwordsCSV(let url):
                do { return ImportBundle(logins: try PasswordsCSV.read(url)) }
                catch { return ImportBundle(warnings: [error.localizedDescription]) }
            }
        }.value
    }
}
