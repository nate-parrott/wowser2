#if os(macOS)
import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1
import NIOSSL
import Security

/// A locally generated certificate authority used by `LocalProxy` to forge
/// per-host leaf certificates so we can MITM HTTPS for our own webviews.
///
/// Trust model: we do *not* install the CA into the system trust store. The
/// CA is trusted only by code paths we control — `WebContent.WebContentWebView`
/// (via `WKNavigationDelegate.didReceive:`) and `URLSession`s we configure
/// for proxy use (via `URLSessionDelegate.didReceive:`). Other apps and the
/// rest of macOS never see it.
///
/// Persistence: the CA's private key is stored in the macOS Keychain under a
/// dedicated service. The matching certificate is cached alongside it. Leaf
/// keys+certs are generated per-host on demand and cached in memory only —
/// they are tiny and trivial to regenerate.
public final class LocalCA: @unchecked Sendable {
    public static let shared = LocalCA(keychainService: "com.wowser.local-ca")

    private let keychainService: String
    private let lock = NSLock()
    private var loadedRoot: (key: P256.Signing.PrivateKey, cert: Certificate)?
    private var leafCache: [String: NIOSSLContext] = [:]

    public init(keychainService: String) {
        self.keychainService = keychainService
    }

    // MARK: - Root CA

    /// Loads an existing root CA from the keychain or generates a new one.
    public func ensureRoot() throws -> (key: P256.Signing.PrivateKey, cert: Certificate) {
        lock.lock(); defer { lock.unlock() }
        if let loadedRoot { return loadedRoot }
        if let existing = try Self.readRoot(keychainService: keychainService) {
            loadedRoot = existing
            return existing
        }
        let new = try Self.generateRoot()
        try Self.writeRoot(keychainService: keychainService, key: new.key, cert: new.cert)
        loadedRoot = new
        return new
    }

    /// Returns the CA cert as a `SecCertificate` so callers can match cert
    /// chains in `URLAuthenticationChallenge.protectionSpace.serverTrust`.
    public func rootSecCertificate() throws -> SecCertificate {
        let root = try ensureRoot()
        var serializer = DER.Serializer()
        try root.cert.serialize(into: &serializer)
        let der = Data(serializer.serializedBytes)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw LocalCAError.derEncodingFailed
        }
        return cert
    }

    /// PEM bytes of the root cert — handy for debugging / for the user to
    /// inspect in Settings.
    public func rootCertPEM() throws -> String {
        let root = try ensureRoot()
        return try root.cert.serializeAsPEM().pemString
    }

    /// Mints a leaf certificate for `host` (signed by the local root) and
    /// returns it as a `SecCertificate`. Used to build a `SecTrust` for
    /// validating that our own webviews accept the proxy's forged leaf certs.
    public func leafSecCertificate(forHost host: String) throws -> SecCertificate {
        let root = try ensureRoot()
        let leaf = try Self.signLeaf(forHost: host, root: root)
        var serializer = DER.Serializer()
        try leaf.cert.serialize(into: &serializer)
        guard let cert = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw LocalCAError.derEncodingFailed
        }
        return cert
    }

    // MARK: - System trust (required for MITM HTTPS in WebKit)
    //
    // WebKit validates a *proxied* origin's TLS cert against the system trust
    // store only — it never delivers a server-trust challenge to the app for
    // proxied connections. So our forged MITM certs are only accepted once this
    // root is installed and trusted in the user's keychain. The proxy gates MITM
    // on `isRootTrusted()`; until the user installs trust, allowlisted HTTPS is
    // blind-tunnelled (loads normally, just uncaptured).

    private let trustLock = NSLock()
    private var rootTrustedCache: Bool?

    /// Whether this CA's root is currently trusted by the system (cached).
    /// Pass `forceRefresh: true` after install/uninstall or to re-check.
    public func isRootTrusted(forceRefresh: Bool = false) -> Bool {
        trustLock.lock()
        if !forceRefresh, let cached = rootTrustedCache { trustLock.unlock(); return cached }
        trustLock.unlock()
        let value = computeRootTrusted()
        trustLock.lock(); rootTrustedCache = value; trustLock.unlock()
        return value
    }

    /// Tests: pretend this CA's root is (or isn't) trusted by the system, so
    /// the proxy's MITM path can be exercised with a throwaway CA.
    func overrideRootTrustedForTesting(_ trusted: Bool) {
        trustLock.lock(); rootTrustedCache = trusted; trustLock.unlock()
    }

    private func computeRootTrusted() -> Bool {
        guard let leaf = try? leafSecCertificate(forHost: "wowser-capture-probe.invalid"),
              let rootSec = try? rootSecCertificate() else { return false }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, rootSec] as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Adds the root to the user keychain and marks it trusted for SSL. Prompts
    /// the user for authentication (Touch ID / password). Call off the main
    /// thread. Idempotent.
    public func installRootAsTrusted() throws {
        let rootSec = try rootSecCertificate()
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: rootSec,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw LocalCAError.keychainAddFailed(addStatus)
        }
        // nil trust settings => trust as a root for all policies (prompts).
        let trustStatus = SecTrustSettingsSetTrustSettings(rootSec, .user, nil)
        guard trustStatus == errSecSuccess else {
            throw LocalCAError.trustSettingsFailed(trustStatus)
        }
        _ = isRootTrusted(forceRefresh: true)
    }

    /// Removes our root's user trust settings and the cached cert. Prompts.
    public func uninstallRootTrust() throws {
        let rootSec = try rootSecCertificate()
        let status = SecTrustSettingsRemoveTrustSettings(rootSec, .user)
        // errSecItemNotFound is fine — nothing to remove.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalCAError.trustSettingsFailed(status)
        }
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: rootSec,
        ] as CFDictionary)
        _ = isRootTrusted(forceRefresh: true)
    }

    // MARK: - Leaf certs (per-host)

    /// Returns a NIOSSL server context wired with a leaf certificate for `host`,
    /// signed by the local CA. Cached after first use per host.
    public func sslServerContext(forHost host: String) throws -> NIOSSLContext {
        lock.lock()
        if let cached = leafCache[host] { lock.unlock(); return cached }
        lock.unlock()

        let root = try ensureRoot()
        let leaf = try Self.signLeaf(forHost: host, root: root)

        // Convert the leaf cert+key to NIOSSL form.
        var leafSerializer = DER.Serializer()
        try leaf.cert.serialize(into: &leafSerializer)
        let leafCertNIOSSL = try NIOSSLCertificate(bytes: leafSerializer.serializedBytes, format: .der)

        let leafKeyPEM = leaf.key.pemRepresentation
        let leafKeyNIOSSL = try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem)

        var rootSerializer = DER.Serializer()
        try root.cert.serialize(into: &rootSerializer)
        let rootCertNIOSSL = try NIOSSLCertificate(bytes: rootSerializer.serializedBytes, format: .der)

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leafCertNIOSSL), .certificate(rootCertNIOSSL)],
            privateKey: .privateKey(leafKeyNIOSSL)
        )
        // We're a forward proxy serving any host on demand; clients don't use SNI to authenticate us.
        config.minimumTLSVersion = .tlsv12

        let ctx = try NIOSSLContext(configuration: config)

        lock.lock()
        leafCache[host] = ctx
        lock.unlock()
        return ctx
    }

    // MARK: - Generation

    private static func generateRoot() throws -> (key: P256.Signing.PrivateKey, cert: Certificate) {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let validityStart = now.addingTimeInterval(-60 * 60 * 24)        // yesterday
        let validityEnd = now.addingTimeInterval(60 * 60 * 24 * 365 * 10) // 10 years
        let subject = try DistinguishedName {
            CommonName("Wowser Local CA")
            OrganizationName("Wowser")
        }
        let issuer = subject
        let pub = Certificate.PublicKey(key.publicKey)

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: pub,
            notValidBefore: validityStart,
            notValidAfter: validityEnd,
            issuer: issuer,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return (key, cert)
    }

    private static func signLeaf(forHost host: String, root: (key: P256.Signing.PrivateKey, cert: Certificate)) throws -> (key: P256.Signing.PrivateKey, cert: Certificate) {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let validityStart = now.addingTimeInterval(-60 * 5)              // 5 min skew
        let validityEnd = now.addingTimeInterval(60 * 60 * 24 * 365)     // 1 year
        let subject = try DistinguishedName {
            CommonName(host)
            OrganizationName("Wowser MITM")
        }
        let pub = Certificate.PublicKey(key.publicKey)

        // Subject Alternative Name: support DNS or IP literal forms.
        let san: SubjectAlternativeNames
        if Self.isIPAddress(host) {
            // Encode as ipAddress GeneralName.
            let bytes = Self.ipAddressBytes(host) ?? []
            san = SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: ArraySlice(bytes)))])
        } else {
            san = SubjectAlternativeNames([.dnsName(host)])
        }

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            KeyUsage(digitalSignature: true, keyEncipherment: true)
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
            san
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: pub,
            notValidBefore: validityStart,
            notValidAfter: validityEnd,
            issuer: root.cert.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(root.key)
        )
        return (key, cert)
    }

    private static func keyIdentifier(for pub: Certificate.PublicKey) -> [UInt8] {
        // SHA-1 over the SubjectPublicKey BIT STRING per RFC 5280.
        // We approximate: hash the DER serialization of the SubjectPublicKeyInfo.
        var serializer = DER.Serializer()
        try? pub.serialize(into: &serializer)
        let digest = Insecure.SHA1.hash(data: Data(serializer.serializedBytes))
        return Array(digest)
    }

    private static func isIPAddress(_ s: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, s, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, s, &ipv6) == 1 { return true }
        return false
    }

    private static func ipAddressBytes(_ s: String) -> [UInt8]? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, s, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, s, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }

    // MARK: - Keychain persistence

    private static let kRootKeyTag = "ca-key"
    private static let kRootCertTag = "ca-cert"

    private static func readRoot(keychainService: String) throws -> (key: P256.Signing.PrivateKey, cert: Certificate)? {
        guard let keyData = readKeychain(service: keychainService, account: kRootKeyTag),
              let certData = readKeychain(service: keychainService, account: kRootCertTag)
        else { return nil }
        let key = try P256.Signing.PrivateKey(rawRepresentation: keyData)
        let cert = try Certificate(derEncoded: Array(certData))
        return (key, cert)
    }

    private static func writeRoot(keychainService: String, key: P256.Signing.PrivateKey, cert: Certificate) throws {
        let keyData = key.rawRepresentation
        var serializer = DER.Serializer()
        try cert.serialize(into: &serializer)
        let certData = Data(serializer.serializedBytes)
        guard writeKeychain(service: keychainService, account: kRootKeyTag, data: keyData),
              writeKeychain(service: keychainService, account: kRootCertTag, data: certData)
        else { throw LocalCAError.keychainWriteFailed }
    }

    private static func readKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        return nil
    }

    private static func writeKeychain(service: String, account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

public enum LocalCAError: Error {
    case derEncodingFailed
    case keychainWriteFailed
    case keychainAddFailed(OSStatus)
    case trustSettingsFailed(OSStatus)
}
#endif
