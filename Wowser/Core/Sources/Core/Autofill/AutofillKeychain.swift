import Foundation
#if canImport(Security)
import Security
#endif

/// Password storage. Each saved login's secret is a generic-password keychain
/// item keyed by (profile, credential id); usernames, hosts and everything
/// else stay in `AutofillStore`'s JSON. Nothing in here is ever logged.
///
/// Prefers the data-protection keychain (no legacy ACL prompts, per-app
/// isolation); falls back to the legacy keychain when the build isn't
/// entitled for it (`errSecMissingEntitlement`).
public enum AutofillKeychain {
    public enum KeychainError: Error, Equatable {
        case unavailable
        case status(Int32)
    }

    static func service(for profile: ID<Profile>) -> String {
        "com.wowser.autofill.\(isProd() ? "prod" : "dev").\(profile.raw)"
    }

    #if canImport(Security)
    private static let missingEntitlement: OSStatus = -34018

    private static func baseQuery(profile: ID<Profile>, credentialID: UUID, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: profile),
            kSecAttrAccount as String: credentialID.uuidString,
        ]
        #if os(macOS)
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    /// Runs `op` against the data-protection keychain, retrying against the
    /// legacy keychain when the entitlement is missing.
    private static func withKeychainVariants(retryOnNotFound: Bool = false, _ op: (Bool) -> OSStatus) -> OSStatus {
        let status = op(true)
        if status == missingEntitlement || (retryOnNotFound && status == errSecItemNotFound) { return op(false) }
        return status
    }

    public static func setPassword(_ password: String, credentialID: UUID, profile: ID<Profile>, label: String) throws {
        let data = Data(password.utf8)
        let status = withKeychainVariants { dp in
            let query = baseQuery(profile: profile, credentialID: credentialID, dataProtection: dp)
            let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
            let s = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if s == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = label
                #if os(macOS)
                // Accessibility classes only apply to the data-protection keychain.
                if dp { add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
                #else
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                #endif
                return SecItemAdd(add as CFDictionary, nil)
            }
            return s
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func password(credentialID: UUID, profile: ID<Profile>) throws -> String? {
        var found: Data?
        // Look in both keychains: without the entitlement, a data-protection
        // *query* can report "not found" (rather than -34018) even though the
        // earlier write fell back to the legacy keychain.
        let status = withKeychainVariants(retryOnNotFound: true) { dp in
            var query = baseQuery(profile: profile, credentialID: credentialID, dataProtection: dp)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let s = SecItemCopyMatching(query as CFDictionary, &item)
            if s == errSecSuccess { found = item as? Data }
            return s
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return found.flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func deletePassword(credentialID: UUID, profile: ID<Profile>) {
        // Both keychains, for the same reason as `password(credentialID:profile:)`.
        for dp in [true, false] {
            _ = SecItemDelete(baseQuery(profile: profile, credentialID: credentialID, dataProtection: dp) as CFDictionary)
        }
    }
    #else
    public static func setPassword(_ password: String, credentialID: UUID, profile: ID<Profile>, label: String) throws { throw KeychainError.unavailable }
    public static func password(credentialID: UUID, profile: ID<Profile>) throws -> String? { throw KeychainError.unavailable }
    public static func deletePassword(credentialID: UUID, profile: ID<Profile>) {}
    #endif
}
