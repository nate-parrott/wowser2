import SwiftUI

/// Settings → Autofill. Toggles, plus an editor for everything autofill
/// remembers per space: names, emails, phones, companies, addresses, saved
/// logins (username editable, password delete-only) and never-remember sites.
struct AutofillSettingsView: View {
    @AppStorage(DefaultsKeys.autofillEnabled.rawValue) private var enabled = true
    @AppStorage(DefaultsKeys.autofillRememberForms.rawValue) private var rememberForms = true
    @AppStorage(DefaultsKeys.autofillSearchableSelects.rawValue) private var searchableSelects = true
    @AppStorage(DefaultsKeys.autofillShareWithAgents.rawValue) private var shareWithAgents = true
    @AppStorage(DefaultsKeys.autofillAgentPasswordFill.rawValue) private var agentPasswordFill = true

    @State private var selectedProfile: ID<Profile>?

    var body: some View {
        // Must put Form WITHIN WithSnapshotMain; cannot put WithSnapshotMain within Form.
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { AutofillProfilesSnapshot(state: $0) }) { profiles in
            let profileID = selectedProfile.flatMap { id in profiles.entries.contains(where: { $0.id == id }) ? id : nil } ?? profiles.current
            WithSnapshotMain(store: AutofillStore.shared, snapshot: { $0[profile: profileID] }) { data in
                Form {
                    togglesSection
                    Section("Space") {
                        Picker("Edit details for", selection: Binding(get: { profileID }, set: { selectedProfile = $0 })) {
                            ForEach(profiles.entries, id: \.id.raw) { entry in
                                Text(entry.displayName).tag(entry.id)
                            }
                        }
                        .help("Autofill data is kept separately for each space.")
                    }
                    AutofillIdentityEditor(profile: profileID, data: data)
                    AutofillPasswordsEditor(profile: profileID, data: data)
                }
                .onDisappear { AutofillStore.shared.save() }
            }
        }
    }

    private var togglesSection: some View {
        Section("Autofill") {
            Toggle("Suggest saved passwords, names and addresses in forms", isOn: $enabled)
                .help("Shows a menu under text fields with matching saved logins, emails, names and addresses. Press Return to fill, Esc to hide.")
            Toggle("Remember what I enter in forms", isOn: $rememberForms)
                .disabled(!enabled)
                .help("When you submit a form, save the login or the name / email / phone / address you typed. A toast lets you forget it or never remember for that site.")
            Toggle("Searchable dropdown menus", isOn: $searchableSelects)
                .help("Replaces the native <select> popup on pages with a menu you can type into to filter options.")
            Toggle("Share my name, email and address with AI agents", isOn: $shareWithAgents)
                .disabled(!enabled)
                .help("Adds your saved name, emails, phone numbers and addresses to browser agents' instructions so they can fill forms for you. Passwords are never shared.")
            Toggle("Let agents fill saved passwords", isOn: $agentPasswordFill)
                .disabled(!enabled)
                .help("Allows browser.credentials.fillPassword in BrowserJS: an agent can type a saved password into a focused password field on the matching site, but never read it.")
        }
    }
}

struct AutofillProfilesSnapshot: Equatable {
    struct Entry: Equatable {
        var id: ID<Profile>
        var displayName: String
    }
    var entries: [Entry]
    var current: ID<Profile>

    init(state: BrowserState) {
        entries = state.profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }).map { profile in
            let name = profile.title?.nilIfEmpty ?? profile.autoTitle?.nilIfEmpty ?? "Space \(profile.creationOrder + 1)"
            let emoji = profile.emoji?.nilIfEmpty.map { "\($0) " } ?? ""
            return Entry(id: profile.id, displayName: emoji + name)
        }
        current = state.activeWindow?.profile ?? entries.first?.id ?? .defaultProfile
    }
}

// MARK: - Identity editor

private struct AutofillIdentityEditor: View {
    var profile: ID<Profile>
    var data: AutofillProfileData

    private var store: AutofillStore { AutofillStore.shared }

    var body: some View {
        Section("Names") {
            ForEach(data.names) { name in
                HStack {
                    TextField("First", text: bind(\.names, id: name.id, \.given))
                    TextField("Last", text: bind(\.names, id: name.id, \.family))
                    deleteButton(id: name.id)
                }
            }
            addButton("Add Name") { $0.names.append(AutofillName(given: "", family: "", useCount: 0)) }
        }
        valuesSection("Emails", placeholder: "name@example.com", keyPath: \.emails)
        valuesSection("Phone Numbers", placeholder: "+1 555 555 5555", keyPath: \.phones)
        valuesSection("Companies", placeholder: "Company", keyPath: \.organizations)
        Section("Addresses") {
            ForEach(data.addresses) { address in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Street address", text: bind(\.addresses, id: address.id, \.line1))
                        deleteButton(id: address.id)
                    }
                    TextField("Apartment, suite, etc.", text: bind(\.addresses, id: address.id, \.line2))
                    HStack {
                        TextField("City", text: bind(\.addresses, id: address.id, \.city))
                        TextField("State", text: bind(\.addresses, id: address.id, \.state))
                        TextField("Postal code", text: bind(\.addresses, id: address.id, \.postalCode))
                    }
                    TextField("Country", text: bind(\.addresses, id: address.id, \.country))
                }
                .padding(.vertical, 4)
            }
            addButton("Add Address") { $0.addresses.append(AutofillAddress(useCount: 0)) }
        }
    }

    @ViewBuilder
    private func valuesSection(_ title: String, placeholder: String, keyPath: WritableKeyPath<AutofillProfileData, [AutofillValue]>) -> some View {
        Section(title) {
            ForEach(data[keyPath: keyPath]) { value in
                HStack {
                    TextField(placeholder, text: bind(keyPath, id: value.id, \.value))
                    deleteButton(id: value.id)
                }
            }
            addButton("Add") { $0[keyPath: keyPath].append(AutofillValue(value: "", useCount: 0)) }
        }
    }

    private func addButton(_ title: String, _ mutate: @escaping (inout AutofillProfileData) -> Void) -> some View {
        Button(title) { store.modifyProfile(profile, mutate) }
    }

    private func deleteButton(id: UUID) -> some View {
        Button {
            store.forget(ids: [id], profile: profile)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private func bind<T: Identifiable>(_ list: WritableKeyPath<AutofillProfileData, [T]>, id: T.ID, _ field: WritableKeyPath<T, String>) -> Binding<String> where T.ID == UUID {
        Binding(
            get: { data[keyPath: list].first(where: { $0.id == id })?[keyPath: field] ?? "" },
            set: { newValue in
                store.modifyProfile(profile) { d in
                    if let i = d[keyPath: list].firstIndex(where: { $0.id == id }) {
                        d[keyPath: list][i][keyPath: field] = newValue
                    }
                }
            }
        )
    }
}

// MARK: - Passwords editor

private struct AutofillPasswordsEditor: View {
    var profile: ID<Profile>
    var data: AutofillProfileData

    private var store: AutofillStore { AutofillStore.shared }
    @State private var newDomain = ""

    var body: some View {
        Section {
            if data.credentials.isEmpty {
                Text("No saved passwords yet. Sign in to a site and choose to remember it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(data.credentials.sorted(by: { $0.lastUsed > $1.lastUsed })) { credential in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential.host)
                            .font(.system(size: 13, weight: .medium))
                        TextField("Username", text: Binding(
                            get: { data.credentials.first(where: { $0.id == credential.id })?.username ?? "" },
                            set: { v in store.modifyProfile(profile) { d in
                                if let i = d.credentials.firstIndex(where: { $0.id == credential.id }) { d.credentials[i].username = v }
                            } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                    Text("••••••••")
                        .foregroundStyle(.secondary)
                        .help("Passwords are kept in your keychain and can't be shown here.")
                    Text(credential.lastUsed.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        store.forget(ids: [credential.id], profile: profile)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this password")
                }
            }
        } header: {
            Text("Passwords")
        } footer: {
            Text("Passwords are stored in the macOS keychain. You can change the username or delete an entry; the password itself is never displayed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Never remember logins on") {
            ForEach(data.neverRememberDomains.sorted(), id: \.self) { domain in
                HStack {
                    Text(domain)
                    Spacer()
                    Button("Remove") { store.allowRememberingAgain(domain: domain, profile: profile) }
                }
            }
            HStack {
                TextField("example.com", text: $newDomain)
                Button("Add") {
                    let d = AutofillHostMatcher.registrableDomain(newDomain.trimmingCharacters(in: .whitespaces))
                    guard !d.isEmpty else { return }
                    store.neverRemember(domain: d, forgetting: [], profile: profile)
                    newDomain = ""
                }
                .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
