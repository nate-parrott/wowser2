import Foundation

// Optional `manifest.json` at the root of a tang:// webapp
// (~/Library/Application Support/Wowser/Apps/<slug>/manifest.json, or
// Core/TangApps/<slug>/manifest.json for apps bundled with the browser).
//
// Gives an app a display title/metadata and lets it register "entry points" —
// hooks that surface the app elsewhere in the browser:
//   - kind "new":    an item in the new-tab "…" menu (below "New Claude")
//   - kind "search": a keyword-triggered result in the omnibox
// (Toolbar buttons are user-owned — see browser.toolbar / BrowserState+Toolbar.)
//
// Each entry point's `bjs` is the body of an async BrowserJS function, run in
// the shared BrowserJS runtime with `browser` and a kind-specific `args`
// object in scope. See BrowserJS.d.ts for the schema and examples.

public struct TangAppManifest: Equatable, Codable {
    public var title: String?
    public var description: String?
    /// Emoji or short string shown next to the app where applicable.
    public var icon: String?
    public var entryPoints: [TangAppEntryPoint]?

    public init(title: String? = nil, description: String? = nil, icon: String? = nil, entryPoints: [TangAppEntryPoint]? = nil) {
        self.title = title
        self.description = description
        self.icon = icon
        self.entryPoints = entryPoints
    }

    enum CodingKeys: String, CodingKey { case title, description, icon, entryPoints }

    /// Entry points with an unknown `kind` are skipped instead of failing the
    /// whole manifest (apps written against an older schema keep working).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        if var list = try? c.nestedUnkeyedContainer(forKey: .entryPoints) {
            var out: [TangAppEntryPoint] = []
            while !list.isAtEnd {
                if let ep = try? list.decode(TangAppEntryPoint.self) {
                    out.append(ep)
                } else {
                    _ = try? list.decode(SkippedEntryPoint.self)
                }
            }
            entryPoints = out
        }
    }
}

private struct SkippedEntryPoint: Decodable { init(from decoder: Decoder) throws {} }

public struct TangAppEntryPoint: Equatable, Codable {
    public enum Kind: String, Codable {
        case new
        case search
    }

    public var kind: Kind
    public var label: String
    /// Required for kind == .search: the leading word that triggers the result
    /// (e.g. "weather" matches queries like "weather" or "weather tomorrow").
    public var keyword: String?
    /// Body of an async BrowserJS function. `browser` and `args` are in scope:
    ///   new:    args = { windowId, profileId }
    ///   search: args = { query, windowId }
    public var bjs: String

    public init(kind: Kind, label: String, keyword: String? = nil, bjs: String) {
        self.kind = kind
        self.label = label
        self.keyword = keyword
        self.bjs = bjs
    }
}

// MARK: - Registry

/// In-memory list of installed tang webapps + their manifests, so menus and
/// the omnibox never touch the disk on render/keystroke paths. Reloaded at
/// launch, on app activation, after `webapp.create`, and when the Apps menu
/// opens.
public final class TangAppRegistry: ObservableObject, @unchecked Sendable {
    public static let shared = TangAppRegistry()

    public struct App: Equatable, Identifiable {
        public var slug: String
        public var manifest: TangAppManifest?
        public var id: String { slug }
        public var title: String { manifest?.title ?? slug }
        public var url: URL? { URL(string: "tang://\(slug)/") }
    }

    /// Main-thread only.
    @Published public private(set) var apps: [App] = []

    private let appStore: TangAppStore

    public init(appStore: TangAppStore = .shared) {
        self.appStore = appStore
    }

    public func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let loaded = self.loadFromDisk()
            DispatchQueue.main.async {
                if loaded != self.apps { self.apps = loaded }
            }
        }
    }

    /// Synchronous variant for deliberate user actions (opening the Apps menu).
    @MainActor public func reloadSync() {
        let loaded = loadFromDisk()
        if loaded != apps { apps = loaded }
    }

    private func loadFromDisk() -> [App] {
        appStore.list().map { slug in
            let manifest = appStore.manifestURL(slug: slug)
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(TangAppManifest.self, from: $0) }
            return App(slug: slug, manifest: manifest)
        }
    }

    /// All entry points of a kind across installed apps. Main-thread only.
    public func entryPoints(_ kind: TangAppEntryPoint.Kind) -> [(app: App, entry: TangAppEntryPoint)] {
        apps.flatMap { app in
            (app.manifest?.entryPoints ?? [])
                .filter { $0.kind == kind }
                .map { (app, $0) }
        }
    }

    public func searchEntryPoint(appSlug: String, label: String) -> (app: App, entry: TangAppEntryPoint)? {
        entryPoints(.search).first(where: { $0.app.slug == appSlug && $0.entry.label == label })
    }
}

// MARK: - Runner

/// Executes a manifest entry point's `bjs` in a shared BrowserJS runtime,
/// with the given args exposed as a `const args` object.
public enum TangAppEntryPointRunner {
    private static let runtime = BrowserJSRuntime(host: BrowserJSLiveHost.shared, helpers: BrowserJSHelpers.shared)

    public static func run(_ entry: TangAppEntryPoint, appSlug: String, args: [String: Any], windowID: ID<WindowState>?) {
        let argsJSON: String = {
            guard JSONSerialization.isValidJSONObject(args),
                  let data = try? JSONSerialization.data(withJSONObject: args),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()
        let code = "const args = \(argsJSON);\n" + entry.bjs
        Task {
            let result = await runtime.run(code: code)
            if let error = result.error {
                let message = "\(appSlug): \(error.prefix(200))"
                await MainActor.run {
                    if let windowID {
                        BrowserStore.shared.modify { $0.addToast(message: message, icon: "puzzlepiece.extension", in: windowID) }
                    }
                }
            }
        }
    }
}
