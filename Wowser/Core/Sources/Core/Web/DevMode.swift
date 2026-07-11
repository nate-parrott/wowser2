import SwiftUI
import Combine

/// A viewport preset for dev mode's mobile letterbox.
public struct DevModeDevice: Identifiable, Hashable {
    public var id: String
    public var width: CGFloat
    public var height: CGFloat

    public var label: String { "\(id) — \(Int(width))×\(Int(height))" }

    public static let all: [DevModeDevice] = [
        .init(id: "iPhone SE", width: 375, height: 667),
        .init(id: "iPhone 13 mini", width: 375, height: 812),
        .init(id: "iPhone 16", width: 393, height: 852),
        .init(id: "iPhone 16 Pro Max", width: 440, height: 956),
        .init(id: "Pixel 8", width: 412, height: 915),
        .init(id: "Galaxy S21", width: 360, height: 800),
        .init(id: "iPad mini", width: 744, height: 1133),
        .init(id: "iPad Pro 11\"", width: 834, height: 1210),
    ]

    public static var `default`: DevModeDevice { all[2] }

    public static func named(_ id: String) -> DevModeDevice {
        all.first(where: { $0.id == id }) ?? .default
    }
}

/// Display scales offered for the mobile letterbox. Zoom only affects how large
/// the device renders on screen; the page still sees the device's point size.
public enum DevModeZoom {
    public static let levels: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    public static let `default`: Double = 1

    public static func label(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// The next level above/below `zoom`, or nil at the end of the range.
    public static func step(from zoom: Double, by direction: Int) -> Double? {
        let idx = levels.firstIndex(where: { abs($0 - zoom) < 0.001 }) ?? levels.firstIndex(of: `default`)!
        let next = idx + direction
        guard levels.indices.contains(next) else { return nil }
        return levels[next]
    }
}

public struct DevModeDomainConfig: Codable, Equatable {
    /// nil means "use the default for this domain" — on for localhost, off otherwise.
    public var enabled: Bool?
    public var mobile = false
    public var deviceID = DevModeDevice.default.id
    /// Whether the webview should send a mobile user agent for this domain.
    public var mobileUserAgent = false
    /// Display scale for the letterbox. Optional so older persisted configs still decode.
    public var zoom: Double?

    public var zoomLevel: Double { zoom ?? DevModeZoom.default }

    public init() {}
}

/// Per-domain developer settings, persisted in UserDefaults.
///
/// Domains are host + explicit port (`localhost:3000`), so two dev servers on
/// the same machine keep separate settings.
@MainActor public final class DevModeStore: ObservableObject {
    public static let shared = DevModeStore()

    @Published private var configs: [String: DevModeDomainConfig]

    private init() {
        configs = Self.load()
    }

    // MARK: - Domain keys

    /// The dev-mode key for a URL, or nil if dev mode doesn't apply (non-http, no host).
    public static func domain(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let host = url.hostWithoutWWW
        guard !host.isEmpty else { return nil }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    public static func isLocalDomain(_ domain: String) -> Bool {
        let host = domain.components(separatedBy: ":").first ?? domain
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host.hasSuffix(".localhost")
    }

    // MARK: - Reads

    public func config(for domain: String) -> DevModeDomainConfig {
        var config = configs[domain] ?? DevModeDomainConfig()
        if config.enabled == nil {
            config.enabled = Self.isLocalDomain(domain)
        }
        return config
    }

    public func isEnabled(for domain: String?) -> Bool {
        guard let domain else { return false }
        return config(for: domain).enabled == true
    }

    // MARK: - Writes

    public func modify(_ domain: String, _ block: (inout DevModeDomainConfig) -> Void) {
        var config = config(for: domain)
        block(&config)
        configs[domain] = config
        save()
    }

    public func setEnabled(_ enabled: Bool, for domain: String) {
        modify(domain) { config in
            config.enabled = enabled
            if !enabled { config.mobile = false }
        }
    }

    // MARK: - Persistence

    private static func load() -> [String: DevModeDomainConfig] {
        guard let data = DefaultsKeys.devModeDomains.stringValue().data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: DevModeDomainConfig].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configs),
              let string = String(data: data, encoding: .utf8) else { return }
        DefaultsKeys.devModeDomains.setString(string)
    }
}

// MARK: - Mobile letterbox

/// Wraps a pane's web content. When dev mode + mobile are on for the current
/// domain, the content is constrained to the chosen device size inside a
/// scrollview, with a device picker beneath it.
struct DevModeMobileContainer<Content: View>: View {
    var webContent: WebContent
    @ViewBuilder var content: () -> Content

    @ObservedObject private var store = DevModeStore.shared
    @State private var domain: String?
    @State private var isNativePage = false

    private var config: DevModeDomainConfig? {
        domain.map { store.config(for: $0) }
    }

    private var isMobileActive: Bool {
        guard !isNativePage, let config else { return false }
        return config.enabled == true && config.mobile
    }

    var body: some View {
        Group {
            if isMobileActive, let domain, let config {
                letterbox(domain: domain, config: config)
            } else {
                content()
            }
        }
        .onReceive(webContent.$info.map({ DevModeStore.domain(for: $0.url) }).removeDuplicates()) { self.domain = $0 }
        .onReceive(webContent.$info.map({ $0.url.flatMap(NativePageKey.init(url:)) != nil }).removeDuplicates()) { self.isNativePage = $0 }
        .onAppearOrChange(of: isMobileActive && config?.mobileUserAgent == true) { wantsMobileUA in
            webContent.usesMobileUserAgent = wantsMobileUA
        }
    }

    @ViewBuilder private func letterbox(domain: String, config: DevModeDomainConfig) -> some View {
        let device = DevModeDevice.named(config.deviceID)
        let zoom = config.zoomLevel
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        VStack(spacing: 0) {
            controls(domain: domain, config: config)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    content()
                        .frame(width: device.width, height: device.height)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(Color.primary.opacity(0.15)) }
                        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                        .scaleEffect(zoom)
                        .frame(width: device.width * zoom, height: device.height * zoom)
                        .padding(20)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        }
        .background(Color.primary.opacity(0.06))
    }

    @ViewBuilder private func controls(domain: String, config: DevModeDomainConfig) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { config.deviceID },
                set: { newValue in store.modify(domain) { $0.deviceID = newValue } }
            )) {
                ForEach(DevModeDevice.all) { device in
                    Text(device.label).tag(device.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            zoomControl(domain: domain, config: config)

            Button(action: { toggleMobileUserAgent(domain: domain, config: config) }) {
                Text(config.mobileUserAgent ? "Reload with desktop user agent" : "Reload for mobile user agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder private func zoomControl(domain: String, config: DevModeDomainConfig) -> some View {
        let zoom = config.zoomLevel

        HStack(spacing: 2) {
            zoomStepButton("minus", from: zoom, by: -1, domain: domain)

            Menu(DevModeZoom.label(zoom)) {
                ForEach(DevModeZoom.levels, id: \.self) { level in
                    Button(DevModeZoom.label(level)) {
                        store.modify(domain) { $0.zoom = level }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

            zoomStepButton("plus", from: zoom, by: 1, domain: domain)
        }
    }

    @ViewBuilder private func zoomStepButton(_ systemImage: String, from zoom: Double, by direction: Int, domain: String) -> some View {
        let next = DevModeZoom.step(from: zoom, by: direction)
        Button {
            if let next { store.modify(domain) { $0.zoom = next } }
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(next == nil ? .tertiary : .secondary)
        .disabled(next == nil)
    }

    private func toggleMobileUserAgent(domain: String, config: DevModeDomainConfig) {
        let wantsMobile = !config.mobileUserAgent
        store.modify(domain) { $0.mobileUserAgent = wantsMobile }
        webContent.usesMobileUserAgent = wantsMobile
        webContent.reload()
    }
}
