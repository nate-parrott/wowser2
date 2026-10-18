import XCTest
import Combine
@testable import Core

/// Autofill and history mappings, synced between two simulated devices.
final class HistoryAutofillSyncTests: XCTestCase {
    var t = Date(timeIntervalSince1970: 3_000_000)

    // MARK: - Autofill

    final class AutofillTestSource: SyncSource {
        let id = "autofill"
        var state = AutofillState()
        var collections: [SyncCollectionSpec] { AutofillSyncSchema.collections }
        var localChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        func project() -> SyncProjection? { state.syncProjection() }
        func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
            state.applySync(update)
            completion()
        }
    }

    func makeAutofill(_ name: String, hub: InMemorySyncHub) -> (AutofillTestSource, SyncEngine) {
        let s = AutofillTestSource()
        let e = SyncEngine(sources: [s], transport: hub.transport(device: name), storage: InMemorySyncEngineStorage(state: SyncEngineState(deviceID: name)), deviceName: name, throttle: 0, now: { [unowned self] in self.t })
        return (s, e)
    }

    func settle(_ engines: [SyncEngine]) {
        for _ in 0..<5 {
            engines.forEach { $0.runUntilQuiet() }
            t = t.addingTimeInterval(1)
        }
    }

    func testAutofillValuesSyncButCredentialsDoNot() {
        let hub = InMemorySyncHub(now: { [unowned self] in self.t })
        let (a, ea) = makeAutofill("A", hub: hub), (b, eb) = makeAutofill("B", hub: hub)
        var data = AutofillProfileData()
        data.emails = [AutofillValue(value: "ada@example.com", lastUsed: Date(timeIntervalSince1970: 100), useCount: 3)]
        data.phones = [AutofillValue(value: "555-0100")]
        data.organizations = [AutofillValue(value: "Analytical Engines")]
        data.names = [AutofillName(given: "Ada", family: "Lovelace")]
        data.addresses = [AutofillAddress(line1: "1 Main St", city: "London", postalCode: "N1")]
        data.credentials = [AutofillCredential(domain: "example.com", host: "example.com", username: "ada")]
        data.neverRememberDomains = ["bank.example"]
        a.state[profile: .defaultProfile] = data
        settle([ea, eb])

        let got = b.state[profile: .defaultProfile]
        XCTAssertEqual(got.emails, data.emails)
        XCTAssertEqual(got.phones.map(\.value), ["555-0100"])
        XCTAssertEqual(got.organizations.map(\.value), ["Analytical Engines"])
        XCTAssertEqual(got.names.map(\.full), ["Ada Lovelace"])
        XCTAssertEqual(got.addresses.map(\.oneLine), data.addresses.map(\.oneLine))
        XCTAssertEqual(got.neverRememberDomains, ["bank.example"])
        XCTAssertTrue(got.credentials.isEmpty, "saved logins never sync")
        XCTAssertFalse(hub.batches(from: "A").flatMap(\.ops).contains { $0.key.contains("credential") || $0.f.lowercased().contains("password") })
    }

    func testAutofillUsageMergesByMax() {
        let hub = InMemorySyncHub(now: { [unowned self] in self.t })
        let (a, ea) = makeAutofill("A", hub: hub), (b, eb) = makeAutofill("B", hub: hub)
        let id = UUID()
        a.state[profile: .defaultProfile].emails = [AutofillValue(id: id, value: "x@example.com", lastUsed: Date(timeIntervalSince1970: 10), useCount: 1)]
        settle([ea, eb])
        a.state[profile: .defaultProfile].emails[0].useCount = 5
        b.state[profile: .defaultProfile].emails[0].lastUsed = Date(timeIntervalSince1970: 99)
        b.state[profile: .defaultProfile].emails[0].useCount = 2
        settle([ea, eb])
        for s in [a, b] {
            XCTAssertEqual(s.state[profile: .defaultProfile].emails.first?.useCount, 5)
            XCTAssertEqual(s.state[profile: .defaultProfile].emails.first?.lastUsed, Date(timeIntervalSince1970: 99))
        }
    }

    func testSameValueRememberedOnBothDevicesConvergesToOneCopy() {
        let hub = InMemorySyncHub(now: { [unowned self] in self.t })
        let (a, ea) = makeAutofill("A", hub: hub), (b, eb) = makeAutofill("B", hub: hub)
        a.state[profile: .defaultProfile].emails = [AutofillValue(value: "dup@example.com")]
        b.state[profile: .defaultProfile].emails = [AutofillValue(value: "DUP@example.com ")]
        ea.runUntilQuiet(); eb.runUntilQuiet()
        settle([ea, eb])
        XCTAssertEqual(a.state[profile: .defaultProfile].emails.count, 1)
        XCTAssertEqual(a.state, b.state)
    }

    func testForgettingAutofillValuePropagates() {
        let hub = InMemorySyncHub(now: { [unowned self] in self.t })
        let (a, ea) = makeAutofill("A", hub: hub), (b, eb) = makeAutofill("B", hub: hub)
        a.state[profile: .defaultProfile].emails = [AutofillValue(value: "gone@example.com"), AutofillValue(value: "kept@example.com")]
        a.state[profile: .defaultProfile].neverRememberDomains = ["x.example"]
        settle([ea, eb])
        b.state[profile: .defaultProfile].emails.removeAll { $0.value == "gone@example.com" }
        b.state[profile: .defaultProfile].neverRememberDomains = []
        settle([ea, eb])
        XCTAssertEqual(a.state[profile: .defaultProfile].emails.map(\.value), ["kept@example.com"])
        XCTAssertEqual(a.state[profile: .defaultProfile].neverRememberDomains, [])
    }

    // MARK: - History

    func testHistoryRecordsRoundTrip() {
        var h = HistoryState()
        let url = URL(string: "https://news.example/")!
        h.modify(url: url) { item in
            item.title = "News"
            item.lastVisit = Date(timeIntervalSince1970: 500)
            item.decayedVisitCount = DecayedCounter(lastCount: 4, lastUpdateDate: Date(timeIntervalSince1970: 500))
        }
        let records = h.syncRecords(group: "G")
        XCTAssertEqual(records.count, 1)
        let (key, fields) = records.first!
        XCTAssertEqual(HistorySyncSchema.parse(key)?.group, "G")

        var other = HistoryState()
        other.applySync(historyKey: HistorySyncSchema.parse(key)!.historyKey, fields: fields, all: fields)
        XCTAssertEqual(other.syncRecords(group: "G"), records)
    }

    func testHistoryOnlyTopPagesSync() {
        var h = HistoryState()
        for i in 0..<(HistorySyncSchema.topCount + 50) {
            h.modify(url: URL(string: "https://p\(i).example/")!) { item in
                item.lastVisit = Date()
                item.decayedVisitCount = DecayedCounter(lastCount: Double(i + 1), lastUpdateDate: Date())
            }
        }
        let records = h.syncRecords(group: "G")
        XCTAssertEqual(records.count, HistorySyncSchema.topCount)
        XCTAssertNil(records[HistorySyncSchema.key(group: "G", historyKey: URL(string: "https://p0.example/")!.historyKey)], "least visited left out")
    }

    func testVisitCountMergeIsTimeIndependent() {
        func f(_ n: Double, _ t: Double, _ ms: Int64) -> SyncField {
            SyncField(v: .object(["n": .number(n), "t": .number(t)]), c: HLC(millis: ms, counter: 0, device: "d\(ms)"))
        }
        let halfLife = TimeInterval.decayedVisitCounterHalfLife
        // 8 visits counted a half-life ago ≈ 4 now: beats 3 visits now.
        let old = f(8, 0, 1), recent = f(3, halfLife, 2)
        XCTAssertEqual(HistorySyncSchema.strongerVisitCount(old, recent), old)
        XCTAssertEqual(HistorySyncSchema.strongerVisitCount(recent, old), old)
        let fresher = f(5, halfLife, 3)
        XCTAssertEqual(HistorySyncSchema.strongerVisitCount(old, fresher), fresher)
    }

    func testHistoryIsGrowOnly() {
        let spec = HistorySyncSchema.collections[0]
        XCTAssertTrue(spec.growOnly)
        var doc = SyncDocument()
        var p = SyncProjection()
        p[HistorySyncSchema.collection, "G|k"] = ["url": .string("https://k.example/"), "lastVisit": .number(1)]
        let (w, prev) = SyncDiff.diff(specs: [spec.name: spec], projection: p, previous: SyncProjection(), doc: doc)
        for (i, write) in w.enumerated() {
            doc.merge(SyncOp(col: write.col, key: write.key, f: write.f, v: write.v, c: HLC(millis: 1, counter: Int32(i), device: "a")), policy: spec.policy)
        }
        p.records[HistorySyncSchema.collection] = [:]
        XCTAssertTrue(SyncDiff.diff(specs: [spec.name: spec], projection: p, previous: prev, doc: doc).writes.isEmpty)
    }
}
