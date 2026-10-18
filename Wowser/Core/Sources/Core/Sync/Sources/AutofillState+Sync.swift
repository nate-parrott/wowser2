import Foundation

// Autofill sync: names, emails, phones, companies, addresses and "never
// remember" domains, per space. Saved logins (and their keychain passwords)
// do NOT sync.

public enum AutofillSyncSchema {
    public static let item = "autofill"
    public static let never = "autofillNever"

    public static var collections: [SyncCollectionSpec] {
        [
            SyncCollectionSpec(name: item, policy: FieldMergePolicy([
                "lastUsed": FieldMergePolicy.maxNumber,
                "useCount": FieldMergePolicy.maxNumber,
            ])),
            SyncCollectionSpec(name: never),
        ]
    }

    enum Kind: String, CaseIterable {
        case name, email, phone, org, address
    }

    static func itemKey(_ profile: ID<Profile>, _ kind: Kind, _ id: UUID) -> String {
        "\(profile.raw)|\(kind.rawValue)|\(id.uuidString)"
    }

    static func parseItemKey(_ key: String) -> (ID<Profile>, Kind, UUID)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])), let id = UUID(uuidString: String(parts[2])) else { return nil }
        return (ID(raw: String(parts[0])), kind, id)
    }

    static func neverKey(_ profile: ID<Profile>, _ domain: String) -> String { "\(profile.raw)|\(domain)" }

    static func parseNeverKey(_ key: String) -> (ID<Profile>, String)? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        return (ID(raw: String(key[..<bar])), String(key[key.index(after: bar)...]))
    }
}

public extension AutofillState {
    func syncProjection() -> SyncProjection {
        typealias S = AutofillSyncSchema
        var p = SyncProjection()
        p.declare(S.item)
        p.declare(S.never)
        for (profile, data) in profiles {
            for n in data.names {
                p[S.item, S.itemKey(profile, .name, n.id)] = ["given": .string(n.given), "family": .string(n.family)].merging(Self.usage(n.lastUsed, n.useCount)) { a, _ in a }
            }
            for (kind, values) in [(S.Kind.email, data.emails), (.phone, data.phones), (.org, data.organizations)] {
                for v in values {
                    p[S.item, S.itemKey(profile, kind, v.id)] = ["value": .string(v.value)].merging(Self.usage(v.lastUsed, v.useCount)) { a, _ in a }
                }
            }
            for a in data.addresses {
                var f: SyncFields = [
                    "line1": .string(a.line1), "line2": .string(a.line2), "city": .string(a.city),
                    "state": .string(a.state), "postalCode": .string(a.postalCode), "country": .string(a.country),
                ]
                f.merge(Self.usage(a.lastUsed, a.useCount)) { a, _ in a }
                p[S.item, S.itemKey(profile, .address, a.id)] = f
            }
            for domain in data.neverRememberDomains {
                p[S.never, S.neverKey(profile, domain)] = ["on": .bool(true)]
            }
        }
        return p
    }

    private static func usage(_ lastUsed: Date, _ count: Int) -> SyncFields {
        ["lastUsed": SyncValue(lastUsed), "useCount": .number(Double(count))]
    }

    mutating func applySync(_ u: SyncUpdate) {
        typealias S = AutofillSyncSchema
        let current = syncProjection()
        for key in u.changedKeys(S.item) {
            guard let (profile, kind, id) = S.parseItemKey(key) else { continue }
            let cur = current[S.item, key]
            if u.shouldDelete(S.item, key, current: cur) {
                _ = self[profile: profile].removeSyncItem(kind, id)
                continue
            }
            guard let fields = u.fieldsToApply(S.item, key, current: cur), !fields.isEmpty || cur == nil else { continue }
            var data = self[profile: profile]
            if cur != nil {
                data.updateSyncItem(kind, id, fields)
            } else if let all = u.doc.fields(S.item, key) {
                data.insertSyncItem(kind, id, all)
            }
            self[profile: profile] = data
        }
        for key in u.changedKeys(S.never) {
            guard let (profile, domain) = S.parseNeverKey(key) else { continue }
            let cur = current[S.never, key]
            if u.shouldDelete(S.never, key, current: cur) {
                self[profile: profile].neverRememberDomains.remove(domain)
            } else if cur == nil, u.doc.isAlive(S.never, key) {
                self[profile: profile].neverRememberDomains.insert(domain)
            }
        }
    }
}

extension AutofillProfileData {
    mutating func removeSyncItem(_ kind: AutofillSyncSchema.Kind, _ id: UUID) -> Bool {
        let before = self
        switch kind {
        case .name: names.removeAll { $0.id == id }
        case .email: emails.removeAll { $0.id == id }
        case .phone: phones.removeAll { $0.id == id }
        case .org: organizations.removeAll { $0.id == id }
        case .address: addresses.removeAll { $0.id == id }
        }
        return before != self
    }

    mutating func updateSyncItem(_ kind: AutofillSyncSchema.Kind, _ id: UUID, _ f: SyncFields) {
        func usage<T>(_ item: inout T, _ lastUsed: WritableKeyPath<T, Date>, _ count: WritableKeyPath<T, Int>) {
            if let d = f["lastUsed"]?.dateValue { item[keyPath: lastUsed] = d }
            if let n = f["useCount"]?.doubleValue { item[keyPath: count] = Int(n) }
        }
        switch kind {
        case .name:
            guard let i = names.firstIndex(where: { $0.id == id }) else { return }
            if let v = f["given"]?.stringValue { names[i].given = v }
            if let v = f["family"]?.stringValue { names[i].family = v }
            usage(&names[i], \.lastUsed, \.useCount)
        case .email, .phone, .org:
            let path: WritableKeyPath<AutofillProfileData, [AutofillValue]> = kind == .email ? \.emails : kind == .phone ? \.phones : \.organizations
            guard let i = self[keyPath: path].firstIndex(where: { $0.id == id }) else { return }
            if let v = f["value"]?.stringValue { self[keyPath: path][i].value = v }
            usage(&self[keyPath: path][i], \.lastUsed, \.useCount)
        case .address:
            guard let i = addresses.firstIndex(where: { $0.id == id }) else { return }
            if let v = f["line1"]?.stringValue { addresses[i].line1 = v }
            if let v = f["line2"]?.stringValue { addresses[i].line2 = v }
            if let v = f["city"]?.stringValue { addresses[i].city = v }
            if let v = f["state"]?.stringValue { addresses[i].state = v }
            if let v = f["postalCode"]?.stringValue { addresses[i].postalCode = v }
            if let v = f["country"]?.stringValue { addresses[i].country = v }
            usage(&addresses[i], \.lastUsed, \.useCount)
        }
    }

    /// Add an item from another device. Both devices may have remembered the
    /// same email (with different ids): the lower id wins on every device, so
    /// they converge on one copy instead of each deleting the other's.
    mutating func insertSyncItem(_ kind: AutofillSyncSchema.Kind, _ id: UUID, _ f: SyncFields) {
        let lastUsed = f["lastUsed"]?.dateValue ?? .distantPast
        let useCount = Int(f["useCount"]?.doubleValue ?? 1)
        func s(_ k: String) -> String { f[k]?.stringValue ?? "" }
        func norm(_ v: String) -> String { v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func resolve<T: Identifiable>(_ items: inout [T], new: T, isDup: (T) -> Bool) where T.ID == UUID {
            if let dup = items.firstIndex(where: { $0.id != id && isDup($0) }) {
                guard id.uuidString < items[dup].id.uuidString else { return }
                items.remove(at: dup)
            }
            items.removeAll { $0.id == id }
            items.append(new)
        }

        switch kind {
        case .name:
            let n = AutofillName(id: id, given: s("given"), family: s("family"), lastUsed: lastUsed, useCount: useCount)
            resolve(&names, new: n) { norm($0.full) == norm(n.full) }
        case .email, .phone, .org:
            let v = AutofillValue(id: id, value: s("value"), lastUsed: lastUsed, useCount: useCount)
            let path: WritableKeyPath<AutofillProfileData, [AutofillValue]> = kind == .email ? \.emails : kind == .phone ? \.phones : \.organizations
            resolve(&self[keyPath: path], new: v) { norm($0.value) == norm(v.value) }
        case .address:
            let a = AutofillAddress(id: id, line1: s("line1"), line2: s("line2"), city: s("city"), state: s("state"), postalCode: s("postalCode"), country: s("country"), lastUsed: lastUsed, useCount: useCount)
            resolve(&addresses, new: a) { $0.isSamePlace(as: a) }
        }
    }
}
