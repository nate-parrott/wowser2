import Foundation
import Combine

// MARK: - Settings

/// Autofill's on/off switches. All default ON; the settings pane writes the
/// same keys via @AppStorage. (`DefaultsKeys.boolValue` ignores its default
/// argument, so "unset means on" is decided here.)
public enum AutofillSettings {
    private static func flag(_ key: DefaultsKeys) -> Bool {
        (UserDefaults.standard.object(forKey: key.rawValue) as? Bool) ?? true
    }

    /// Master switch: suggestions under fields + agent hooks.
    public static var isEnabled: Bool { flag(.autofillEnabled) }
    /// Remember what the user submits in forms (logins, name, address…).
    public static var remembersForms: Bool { isEnabled && flag(.autofillRememberForms) }
    /// Replace the native `<select>` popup with the searchable menu.
    public static var searchableSelects: Bool { flag(.autofillSearchableSelects) }
    /// Put name / email / address in agents' system prompts.
    public static var sharesIdentityWithAgents: Bool { isEnabled && flag(.autofillShareWithAgents) }
    /// Let agents type a saved password into a password field via BrowserJS.
    public static var agentsMayFillPasswords: Bool { isEnabled && flag(.autofillAgentPasswordFill) }
}

// MARK: - Store

/// Persists the non-secret autofill data (`AutofillState`) as JSON next to
/// the other data stores, and brokers passwords to/from the keychain on a
/// background queue. Business logic lives in `AutofillState+Operations`.
public final class AutofillStore: DataStore<AutofillState> {
    public static let shared = AutofillStore(persistenceKey: "AutofillStore", defaultModel: AutofillState(), queue: .main)

    private let keychainQueue = DispatchQueue(label: "wowser.autofill.keychain", qos: .userInitiated)

    // MARK: Profile resolution

    /// The space/profile that owns a webview, by its website data store.
    /// (Ghost/agent tabs have no window, so this beats window lookup.)
    /// Spaces that share a data store share autofill, kept under one owner.
    public func profileID(forDatastoreUUID uuid: UUID) -> ID<Profile>? {
        BrowserStore.shared.model.autofillOwner(ofDataStore: uuid)
    }

    /// The profile shown in the most recently active window.
    public func currentProfileID() -> ID<Profile> {
        BrowserStore.shared.model.activeWindow?.profile ?? .defaultProfile
    }

    public func data(for profile: ID<Profile>) -> AutofillProfileData {
        model[profile: profile]
    }

    public func modifyProfile(_ profile: ID<Profile>, _ block: @escaping (inout AutofillProfileData) -> Void) {
        modify { state in
            var data = state[profile: profile]
            block(&data)
            state[profile: profile] = data
        }
    }

    // MARK: Passwords

    public func password(for credential: AutofillCredential, profile: ID<Profile>) async -> String? {
        await withCheckedContinuation { cont in
            keychainQueue.async {
                let pw = try? AutofillKeychain.password(credentialID: credential.id, profile: profile)
                cont.resume(returning: pw)
            }
        }
    }

    public func setPassword(_ password: String, for credential: AutofillCredential, profile: ID<Profile>) async -> Bool {
        await withCheckedContinuation { cont in
            keychainQueue.async {
                do {
                    try AutofillKeychain.setPassword(password, credentialID: credential.id, profile: profile, label: "\(credential.host) (\(credential.username))")
                    cont.resume(returning: true)
                } catch {
                    print("[autofill] keychain write failed: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
    }

    public func deletePasswords(credentialIDs: [UUID], profile: ID<Profile>) {
        guard !credentialIDs.isEmpty else { return }
        keychainQueue.async {
            for id in credentialIDs { AutofillKeychain.deletePassword(credentialID: id, profile: profile) }
        }
    }

    // MARK: Forget / never

    /// Removes records (and their keychain secrets).
    public func forget(ids: [UUID], profile: ID<Profile>) {
        var removedCredentials: [UUID] = []
        modifyProfile(profile) { data in
            removedCredentials = data.forget(ids: Set(ids))
        }
        deletePasswords(credentialIDs: removedCredentials, profile: profile)
        save()
    }

    public func neverRemember(domain: String, forgetting ids: [UUID], profile: ID<Profile>) {
        var removedCredentials: [UUID] = []
        modifyProfile(profile) { data in
            removedCredentials = data.forget(ids: Set(ids))
            removedCredentials += data.neverRemember(domain: domain)
        }
        deletePasswords(credentialIDs: removedCredentials, profile: profile)
        save()
    }

    public func allowRememberingAgain(domain: String, profile: ID<Profile>) {
        modifyProfile(profile) { data in
            data.neverRememberDomains.remove(AutofillHostMatcher.registrableDomain(domain))
        }
        save()
    }

    /// Records that a suggestion was used (bumps its ranking).
    public func markUsed(_ payload: AutofillSuggestion.Payload, profile: ID<Profile>) {
        modifyProfile(profile) { $0.markUsed(payload) }
    }

    // MARK: Remembering a submitted form

    /// Folds a submission into the profile, stores the password, and shows the
    /// "Saved …" toast with Forget / Never actions. Silent when nothing new was
    /// learned (same login, same password).
    @MainActor
    public func handleSubmission(_ submission: AutofillFormSubmission, profile: ID<Profile>, windowID: ID<WindowState>?) async {
        guard AutofillSettings.remembersForms else { return }
        // Remember against the current data, but only commit once we know
        // whether the password actually changed (so a routine sign-in with a
        // known password doesn't nag).
        var trial = data(for: profile)
        guard let outcome = trial.remember(submission) else { return }

        var passwordChanged = false
        if let credential = outcome.credential, let password = outcome.password {
            let existing = outcome.isNewCredential ? nil : await self.password(for: credential, profile: profile)
            passwordChanged = existing != password
        }
        let identitySaved = !outcome.savedIdentityKinds.isEmpty
        let hasNews = passwordChanged || outcome.isNewCredential || identitySaved

        // Commit (bumps use counts / lastUsed even when nothing is new).
        let committed = trial
        modify { state in state[profile: profile] = committed }
        if let credential = outcome.credential, let password = outcome.password, passwordChanged {
            _ = await setPassword(password, for: credential, profile: profile)
        }
        save()

        guard hasNews, let windowID else { return }
        let host = submission.url.host ?? ""
        let domain = AutofillHostMatcher.registrableDomain(host)
        var parts: [String] = []
        if outcome.credential != nil, passwordChanged || outcome.isNewCredential {
            parts.append(outcome.isNewCredential ? "username and password" : "updated password")
        }
        let identityNames = outcome.savedIdentityKinds.compactMap { kind -> String? in
            switch kind {
            case .fullName: return "name"
            case .email: return "email"
            case .phone: return "phone"
            case .organization: return "company"
            case .streetAddress: return "address"
            default: return nil
            }
        }
        parts += identityNames
        let what = parts.isEmpty ? "form details" : ListFormatter.localizedString(byJoining: parts)
        let message = "Saved \(what) for \(domain.isEmpty ? host : domain)"
        let actions = [
            ToastAction(title: "Forget", kind: .autofillForget(profile: profile, ids: outcome.touchedIDs)),
            ToastAction(title: "Never for this site", kind: .autofillNeverRemember(profile: profile, domain: domain, ids: outcome.touchedIDs)),
        ]
        BrowserStore.shared.modify { state in
            state.addToast(Toast(message: message, icon: "key.fill", actions: actions, dismissAfter: 10), in: windowID)
        }
    }
}

// MARK: - Agent system prompt

public extension AutofillStore {
    /// The "who the user is" section appended to browser agents' system
    /// prompts (name, emails, phones, addresses — never passwords). nil when
    /// sharing is off or nothing is saved. Safe to call from any actor.
    static func agentIdentitySection() async -> String? {
        await MainActor.run {
            guard AutofillSettings.sharesIdentityWithAgents else { return nil }
            let profile = shared.currentProfileID()
            guard let summary = shared.data(for: profile).systemPromptSummary() else { return nil }
            return """
            ## The user (from their autofill profile)

            Use these details whenever a page asks for the user's own information \
            (checkout, sign-up, contact forms); `browser.profile.get()` returns the \
            same data as JSON.

            \(summary)

            Passwords are never given to you. To sign the user in, put the cursor in \
            the password field on the matching site and call \
            `await browser.credentials.fillPassword(tabId, { username })`; use \
            `browser.credentials.lookup(domain)` / `hasPassword(domain)` to see what is saved.
            """
        }
    }
}

extension BrowserState {
    /// The profile whose autofill data a website data store uses: the
    /// earliest-created space with that store (spaces "sharing logins" share
    /// one). Deterministic, unlike dictionary order.
    func autofillOwner(ofDataStore uuid: UUID) -> ID<Profile>? {
        profiles.values
            .filter { $0.dataStoreUUID == uuid }
            .min { ($0.creationOrder, $0.id.raw) < ($1.creationOrder, $1.id.raw) }?
            .id
    }
}
