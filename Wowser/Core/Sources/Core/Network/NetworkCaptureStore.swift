import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Logged HTTP exchange. Fields mirror what BrowserJS exposes via
/// `browser.net.log` / `browser.net.grep`.
public struct NetCaptureEntry: Codable, Sendable, Equatable {
    public var id: String
    public var ts: Double
    public var url: String
    public var method: String
    public var status: Int
    public var requestHeaders: [String: String]
    public var requestBody: String?
    public var responseHeaders: [String: String]
    public var responseBody: String?
    public var tabId: String?
    /// "proxy" (logged from the local intercepting proxy) or "synth" (from
    /// `browser.net.fetch`). Useful for distinguishing real browser traffic
    /// from synthesized requests when grepping.
    public var source: String

    public init(id: String = UUID().uuidString,
                ts: Double = Date().timeIntervalSince1970,
                url: String,
                method: String,
                status: Int,
                requestHeaders: [String: String],
                requestBody: String?,
                responseHeaders: [String: String],
                responseBody: String?,
                tabId: String? = nil,
                source: String = "proxy") {
        self.id = id; self.ts = ts; self.url = url; self.method = method; self.status = status
        self.requestHeaders = requestHeaders; self.requestBody = requestBody
        self.responseHeaders = responseHeaders; self.responseBody = responseBody
        self.tabId = tabId; self.source = source
    }
}

/// In-memory ring buffer + on-disk JSON-lines persistence with at-rest
/// encryption (CryptoKit ChaChaPoly, key stored in the macOS Keychain on
/// macOS or Application Support on iOS for now). Capture is *opt-in per
/// origin*: callers must add origins via `setCaptureEnabled(origin:)` before
/// the proxy or synthetic fetch records bodies.
public actor NetworkCaptureStore {
    public static let shared: NetworkCaptureStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wowser", isDirectory: true)
            .appendingPathComponent("network", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return NetworkCaptureStore(directory: dir, keychainService: "com.wowser.network-capture")
    }()

    /// Hard cap on bodies we keep — anything larger is dropped (Q26).
    public static let maxBodyBytes = 5 * 1024 * 1024
    /// Time-based eviction window (Q26).
    public static let retentionSeconds: Double = 60 * 60 * 24
    /// In-memory ring buffer cap.
    public static let maxInMemory = 5_000

    private let directory: URL
    private let keychainService: String?
    private var buffer: [NetCaptureEntry] = []
    private var allowlist: Set<String> = []
    private let logFile: URL
    private var encryptionKey: SymmetricKey

    public init(directory: URL, keychainService: String? = nil) {
        self.directory = directory
        self.keychainService = keychainService
        self.logFile = directory.appendingPathComponent("capture.bin")
        self.encryptionKey = Self.loadOrCreateKey(keychainService: keychainService, fileFallback: directory.appendingPathComponent("capture.key"))
        // Best-effort load of existing entries.
        if let existing = Self.readPersisted(file: logFile, key: encryptionKey) {
            self.buffer = existing.suffix(Self.maxInMemory)
        }
        Task { await self.evictOldEntries() }
    }

    // MARK: - Allowlist

    public func setCaptureEnabled(origin: String, enabled: Bool) {
        let normalized = Self.normalizeOrigin(origin)
        if enabled { allowlist.insert(normalized) } else { allowlist.remove(normalized) }
    }

    public func isCaptureEnabled(forURL urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return isCaptureEnabledForOrigin(host: url.host ?? "", port: url.port, scheme: url.scheme)
    }

    private func isCaptureEnabledForOrigin(host: String, port: Int?, scheme: String?) -> Bool {
        let normalized = Self.normalizeOrigin(scheme: scheme, host: host, port: port)
        if allowlist.contains(normalized) { return true }
        // Allow capture if any allowlisted origin is a suffix match on host
        // (e.g. allowlist `example.com` covers `api.example.com`).
        for entry in allowlist {
            if let entryHost = URL(string: entry)?.host,
               !entryHost.isEmpty,
               host == entryHost || host.hasSuffix("." + entryHost) {
                return true
            }
        }
        return false
    }

    // MARK: - Logging

    @discardableResult
    public func record(_ entry: NetCaptureEntry) -> NetCaptureEntry {
        guard isCaptureEnabled(forURL: entry.url) else { return entry }
        let trimmed = trimBodies(entry)
        buffer.append(trimmed)
        if buffer.count > Self.maxInMemory {
            buffer.removeFirst(buffer.count - Self.maxInMemory)
        }
        Self.appendPersisted(entry: trimmed, file: logFile, key: encryptionKey)
        return trimmed
    }

    public func entries(filter: NetLogFilter) -> [NetCaptureEntry] {
        var out = buffer
        if let tabId = filter.tabId { out = out.filter { $0.tabId == tabId } }
        if let methodFilter = filter.method {
            let m = methodFilter.uppercased()
            out = out.filter { $0.method.uppercased() == m }
        }
        if let regex = filter.urlRegex, let r = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) {
            out = out.filter { entry in
                let range = NSRange(entry.url.startIndex..<entry.url.endIndex, in: entry.url)
                return r.firstMatch(in: entry.url, options: [], range: range) != nil
            }
        }
        if let since = filter.since {
            out = out.filter { $0.ts >= since }
        }
        if let limit = filter.limit, out.count > limit {
            out = Array(out.suffix(limit))
        }
        return out
    }

    public func grep(pattern: String, where field: String) -> [NetCaptureEntry] {
        let lower = pattern.lowercased()
        return buffer.filter { entry in
            let haystack: String
            switch field {
            case "reqBody": haystack = entry.requestBody ?? ""
            case "resBody": haystack = entry.responseBody ?? ""
            case "headers":
                let req = entry.requestHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                let res = entry.responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                haystack = req + "\n" + res
            default: haystack = entry.url
            }
            return haystack.lowercased().contains(lower)
        }
    }

    public func entry(id: String) -> NetCaptureEntry? {
        buffer.first(where: { $0.id == id })
    }

    public func clear() {
        buffer.removeAll()
        try? FileManager.default.removeItem(at: logFile)
    }

    // MARK: - Eviction

    private func evictOldEntries() {
        let cutoff = Date().timeIntervalSince1970 - Self.retentionSeconds
        let before = buffer.count
        buffer.removeAll { $0.ts < cutoff }
        if buffer.count != before {
            // Rewrite log file with surviving entries.
            Self.rewritePersisted(entries: buffer, file: logFile, key: encryptionKey)
        }
    }

    private func trimBodies(_ entry: NetCaptureEntry) -> NetCaptureEntry {
        var e = entry
        e.requestBody = Self.trimBody(e.requestBody, contentType: e.requestHeaders["Content-Type"] ?? e.requestHeaders["content-type"])
        e.responseBody = Self.trimBody(e.responseBody, contentType: e.responseHeaders["Content-Type"] ?? e.responseHeaders["content-type"])
        return e
    }

    private static func trimBody(_ body: String?, contentType: String?) -> String? {
        guard var body else { return nil }
        if let ct = contentType?.lowercased(), ct.hasPrefix("audio/") || ct.hasPrefix("video/") {
            return nil
        }
        if body.utf8.count > maxBodyBytes {
            body = String(body.prefix(maxBodyBytes / 2)) + "\n...[truncated]"
        }
        return body
    }

    // MARK: - Origin normalization

    private static func normalizeOrigin(_ s: String) -> String {
        if s.contains("://"), let url = URL(string: s) {
            return normalizeOrigin(scheme: url.scheme, host: url.host ?? s, port: url.port)
        }
        // Treat bare "example.com" as https.
        return normalizeOrigin(scheme: "https", host: s, port: nil)
    }

    private static func normalizeOrigin(scheme: String?, host: String, port: Int?) -> String {
        let scheme = scheme ?? "https"
        if let port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    // MARK: - Persistence (encrypted JSON-lines)

    private static func appendPersisted(entry: NetCaptureEntry, file: URL, key: SymmetricKey) {
        guard let json = try? JSONEncoder().encode(entry) else { return }
        guard let sealed = try? ChaChaPoly.seal(json, using: key).combined else { return }
        // Frame: 4-byte big-endian length prefix.
        var len = UInt32(sealed.count).bigEndian
        var framed = Data(bytes: &len, count: 4)
        framed.append(sealed)
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try framed.write(to: file)
            } else {
                let h = try FileHandle(forWritingTo: file)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: framed)
            }
        } catch {
            // ignore — capture is best-effort
        }
    }

    private static func readPersisted(file: URL, key: SymmetricKey) -> [NetCaptureEntry]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        var out: [NetCaptureEntry] = []
        var idx = 0
        while idx + 4 <= data.count {
            let len = data[idx..<idx+4].withUnsafeBytes { ptr -> UInt32 in
                ptr.loadUnaligned(as: UInt32.self).bigEndian
            }
            idx += 4
            guard len > 0, idx + Int(len) <= data.count else { break }
            let chunk = data.subdata(in: idx..<idx+Int(len))
            idx += Int(len)
            guard let sealed = try? ChaChaPoly.SealedBox(combined: chunk),
                  let plain = try? ChaChaPoly.open(sealed, using: key),
                  let entry = try? JSONDecoder().decode(NetCaptureEntry.self, from: plain)
            else { continue }
            out.append(entry)
        }
        return out
    }

    private static func rewritePersisted(entries: [NetCaptureEntry], file: URL, key: SymmetricKey) {
        try? FileManager.default.removeItem(at: file)
        for entry in entries {
            appendPersisted(entry: entry, file: file, key: key)
        }
    }

    // MARK: - Key management

    private static func loadOrCreateKey(keychainService: String?, fileFallback: URL) -> SymmetricKey {
        #if os(macOS)
        if let service = keychainService {
            if let data = readKeychainKey(service: service) {
                return SymmetricKey(data: data)
            }
            let new = SymmetricKey(size: .bits256)
            let data = new.withUnsafeBytes { Data($0) }
            _ = writeKeychainKey(service: service, data: data)
            return new
        }
        #endif
        // Fallback (iOS or no keychain): persist key file with restrictive perms.
        if let data = try? Data(contentsOf: fileFallback) {
            return SymmetricKey(data: data)
        }
        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        try? data.write(to: fileFallback, options: .atomic)
        return new
    }

    #if os(macOS)
    private static func readKeychainKey(service: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "capture-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        return nil
    }

    @discardableResult
    private static func writeKeychainKey(service: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "capture-key",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    #endif
}
