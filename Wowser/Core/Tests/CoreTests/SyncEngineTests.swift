import XCTest
import Combine
@testable import Core

/// A minimal source: a dictionary of items (with string fields) plus one
/// ordered list per parent. Applies synchronously, or queues applies when
/// `deferApplies` is set (to simulate the main-thread hop).
final class ToySyncSource: SyncSource {
    struct Model: Equatable {
        var items: [String: [String: String]] = [:]
        var lists: [String: [String]] = [:]
        /// Items the source can't absorb (exercise divergence).
        var stubborn: Set<String> = []
    }

    let id = "toy"
    var model = Model()
    var deferApplies = false
    var pendingApplies: [() -> Void] = []
    var applyCount = 0
    let changes = PassthroughSubject<Void, Never>()

    var collections: [SyncCollectionSpec] {
        [SyncCollectionSpec(name: "item", ordered: true), SyncCollectionSpec(name: "counter", policy: FieldMergePolicy(["n": FieldMergePolicy.maxNumber]))]
    }
    var localChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    func project() -> SyncProjection? {
        Self.project(model)
    }

    static func project(_ model: Model) -> SyncProjection {
        var p = SyncProjection()
        p.declare("item")
        for (key, fields) in model.items {
            p["item", key] = fields.mapValues { .string($0) }
        }
        for (parent, keys) in model.lists {
            for k in keys { p.append(k, to: parent, in: "item") }
        }
        return p
    }

    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        let work = { [self] in
            applyCount += 1
            let current = Self.project(model)
            for key in update.changedKeys("item") {
                if update.shouldDelete("item", key, current: current["item", key]) {
                    model.items[key] = nil
                    for p in model.lists.keys { model.lists[p]?.removeAll { $0 == key } }
                    continue
                }
                guard !model.stubborn.contains(key),
                      let fields = update.fieldsToApply("item", key, current: current["item", key]) else { continue }
                var item = model.items[key] ?? [:]
                for (f, v) in fields { item[f] = v.stringValue }
                model.items[key] = item
            }
            // Reorder every list touched, plus lists of items we just created.
            var parents = update.changedParents["item"] ?? []
            parents.formUnion(model.lists.keys)
            for parent in parents.sorted() {
                let local = model.lists[parent] ?? []
                guard let desired = update.desiredOrder("item", parent: parent, local: local) else { continue }
                // Make sure no item ends up in two lists.
                for other in model.lists.keys where other != parent {
                    model.lists[other]?.removeAll { desired.contains($0) }
                }
                model.lists[parent] = desired.filter { model.items[$0] != nil || update.doc.isAlive("item", $0) }
                for k in desired where model.items[k] == nil { model.items[k] = [:] }
            }
            model.lists = model.lists.filter { !$0.value.isEmpty }
            completion()
        }
        if deferApplies { pendingApplies.append(work) } else { work() }
    }

    func runPendingApplies() {
        let p = pendingApplies
        pendingApplies = []
        p.forEach { $0() }
    }

    // Local edits
    func set(_ key: String, _ f: String, _ v: String?) {
        model.items[key, default: [:]][f] = v
    }
    func insert(_ key: String, into parent: String, at idx: Int? = nil, fields: [String: String] = [:]) {
        model.items[key] = fields
        var list = model.lists[parent] ?? []
        list.insert(key, at: min(idx ?? list.count, list.count))
        model.lists[parent] = list
    }
    func delete(_ key: String) {
        model.items[key] = nil
        for p in model.lists.keys { model.lists[p]?.removeAll { $0 == key } }
        model.lists = model.lists.filter { !$0.value.isEmpty }
    }
    func move(_ key: String, to parent: String, at idx: Int) {
        for p in model.lists.keys { model.lists[p]?.removeAll { $0 == key } }
        var list = model.lists[parent] ?? []
        list.insert(key, at: min(idx, list.count))
        model.lists[parent] = list
        model.lists = model.lists.filter { !$0.value.isEmpty }
    }
}

final class SyncEngineTests: XCTestCase {
    var t = Date(timeIntervalSince1970: 1_000_000)

    final class Replica {
        let source: ToySyncSource
        let engine: SyncEngine
        let transport: InMemorySyncTransport
        let storage: InMemorySyncEngineStorage
        init(source: ToySyncSource, engine: SyncEngine, transport: InMemorySyncTransport, storage: InMemorySyncEngineStorage) {
            self.source = source; self.engine = engine; self.transport = transport; self.storage = storage
        }
        func sync() { engine.runUntilQuiet() }
    }

    func makeHub(latency: ClosedRange<TimeInterval> = 0...0, seed: UInt64 = 1) -> InMemorySyncHub {
        InMemorySyncHub(latency: latency, seed: seed, now: { [unowned self] in self.t })
    }

    func makeReplica(_ name: String, hub: InMemorySyncHub, storage: InMemorySyncEngineStorage? = nil, source: ToySyncSource? = nil) -> Replica {
        let storage = storage ?? InMemorySyncEngineStorage(state: SyncEngineState(deviceID: name))
        let source = source ?? ToySyncSource()
        let transport = hub.transport(device: storage.state?.deviceID ?? name)
        let engine = SyncEngine(sources: [source], transport: transport, storage: storage, deviceName: name, throttle: 0, now: { [unowned self] in self.t })
        return Replica(source: source, engine: engine, transport: transport, storage: storage)
    }

    func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }

    /// Sync everyone repeatedly until nothing moves (latency elapsed).
    func settle(_ replicas: [Replica], rounds: Int = 6) {
        for _ in 0..<rounds {
            for r in replicas { r.sync() }
            advance(5)
        }
    }

    // MARK: - Basics

    func testTwoReplicasConverge() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        settle([a, b])
        a.source.insert("x", into: "L", fields: ["title": "Hello"])
        a.source.insert("y", into: "L", fields: ["title": "World"])
        settle([a, b])
        XCTAssertEqual(b.source.model.items["x"], ["title": "Hello"])
        XCTAssertEqual(b.source.model.lists["L"], ["x", "y"])

        b.source.set("x", "title", "Hi")
        b.source.move("y", to: "L", at: 0)
        settle([a, b])
        XCTAssertEqual(a.source.model, b.source.model)
        XCTAssertEqual(a.source.model.lists["L"], ["y", "x"])
        XCTAssertEqual(a.source.model.items["x"]?["title"], "Hi")

        a.source.delete("y")
        settle([a, b])
        XCTAssertEqual(b.source.model.lists["L"], ["x"])
        XCTAssertNil(b.source.model.items["y"])
    }

    func testQuiescentReplicasWriteNothing() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "Hello"])
        settle([a, b])
        let before = hub.batches(from: "A").count + hub.batches(from: "B").count
        settle([a, b], rounds: 10)
        XCTAssertEqual(hub.batches(from: "A").count + hub.batches(from: "B").count, before, "no echo / ping-pong")
    }

    func testConcurrentEditsToSameFieldConvergeAndAreLogged() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "Start"])
        settle([a, b])
        a.source.set("x", "title", "From A")
        a.sync()
        advance(0.001)
        b.source.set("x", "title", "From B")
        b.sync()
        settle([a, b])
        XCTAssertEqual(a.source.model, b.source.model)
        XCTAssertEqual(a.source.model.items["x"]?["title"], "From B", "later write wins")
        let conflicts = a.engine.status.conflicts + b.engine.status.conflicts
        XCTAssertTrue(conflicts.contains { $0.key == "x" && $0.field == "title" && $0.winnerValue == "From B" && $0.loserValue == "From A" })
    }

    func testConcurrentEditsToDifferentFieldsBothSurvive() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T", "emoji": "E"])
        settle([a, b])
        a.source.set("x", "title", "T2")
        b.source.set("x", "emoji", "E2")
        a.sync(); b.sync()
        settle([a, b])
        XCTAssertEqual(a.source.model.items["x"], ["title": "T2", "emoji": "E2"])
        XCTAssertEqual(a.source.model, b.source.model)
    }

    func testDeleteWinsOverConcurrentEdit() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        a.source.delete("x")
        a.sync()
        advance(1)
        b.source.set("x", "title", "edited later")
        b.sync()
        settle([a, b])
        XCTAssertNil(a.source.model.items["x"])
        XCTAssertNil(b.source.model.items["x"])
    }

    func testConcurrentMovesConvergeToSameOrder() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        for k in ["1", "2", "3", "4", "5"] { a.source.insert(k, into: "L") }
        settle([a, b])
        a.source.move("5", to: "L", at: 0)
        b.source.move("1", to: "L", at: 4)
        b.source.insert("new", into: "L", at: 2)
        a.sync(); b.sync()
        settle([a, b])
        XCTAssertEqual(a.source.model.lists, b.source.model.lists)
        XCTAssertEqual(a.source.model.lists["L"], ["5", "2", "3", "new", "4", "1"])
    }

    func testConcurrentInsertsAtSameSpotKeepBoth() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("1", into: "L"); a.source.insert("2", into: "L")
        settle([a, b])
        a.source.insert("fromA", into: "L", at: 1)
        b.source.insert("fromB", into: "L", at: 1)
        a.sync(); b.sync()
        settle([a, b])
        XCTAssertEqual(a.source.model.lists, b.source.model.lists)
        XCTAssertEqual(Set(a.source.model.lists["L"]!), ["1", "2", "fromA", "fromB"])
        XCTAssertEqual(a.source.model.lists["L"]!.first, "1")
        XCTAssertEqual(a.source.model.lists["L"]!.last, "2")
    }

    func testMoveBetweenLists() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L"); a.source.insert("y", into: "L")
        settle([a, b])
        b.source.move("x", to: "M", at: 0)
        settle([a, b])
        XCTAssertEqual(a.source.model.lists["L"], ["y"])
        XCTAssertEqual(a.source.model.lists["M"], ["x"])
    }

    // MARK: - Joining

    func testJoinPushesLocalOnlyRecordsAndAdoptsRemoteForSharedKeys() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub)
        a.source.insert("shared", into: "L", fields: ["title": "Remote title"])
        a.source.insert("a1", into: "L")
        settle([a])

        let bSource = ToySyncSource()
        bSource.insert("shared", into: "L", fields: ["title": "Local title"])
        bSource.insert("b1", into: "L")
        let b = makeReplica("B", hub: hub, source: bSource)
        settle([a, b])

        XCTAssertEqual(a.source.model, b.source.model)
        XCTAssertEqual(b.source.model.items["shared"]?["title"], "Remote title", "joining device adopts existing values")
        XCTAssertEqual(Set(b.source.model.lists["L"]!), ["shared", "a1", "b1"])
    }

    func testRestartDoesNotRewriteAndCatchesUp() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        b.engine.flush()
        let sentBefore = hub.batches(from: "B").count

        // "Quit" B; A keeps editing.
        let bModel = b.source.model
        a.source.set("x", "title", "While B was away")
        settle([a])

        let restartedSource = ToySyncSource()
        restartedSource.model = bModel
        let b2 = makeReplica("B", hub: hub, storage: b.storage, source: restartedSource)
        settle([a, b2])
        XCTAssertEqual(hub.batches(from: "B").count, sentBefore, "nothing new to say after restart")
        XCTAssertEqual(b2.source.model.items["x"]?["title"], "While B was away")
    }

    func testEditsMadeWhileQuitAreSentOnRestart() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        b.engine.flush()
        var bModel = b.source.model
        bModel.items["x"]?["title"] = "Edited offline"
        let restartedSource = ToySyncSource()
        restartedSource.model = bModel
        let b2 = makeReplica("B", hub: hub, storage: b.storage, source: restartedSource)
        settle([a, b2])
        XCTAssertEqual(a.source.model.items["x"]?["title"], "Edited offline")
    }

    // MARK: - Robustness

    func testOutboxRetriesAfterTransportFailure() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.transport.failPublishes = true
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        XCTAssertNil(b.source.model.items["x"])
        XCTAssertEqual(a.engine.status.outboxCount, 1)
        XCTAssertTrue(a.engine.status.errors.first?.message.contains("Publish failed") == true)
        a.transport.failPublishes = false
        settle([a, b])
        XCTAssertEqual(b.source.model.items["x"], ["title": "T"])
        XCTAssertEqual(a.engine.status.outboxCount, 0)
    }

    func testSnapshotCompactionStillBootstrapsNewDevice() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub)
        a.transport.snapshotEvery = 3
        for i in 0..<10 {
            a.source.insert("k\(i)", into: "L", fields: ["n": "\(i)"])
            if i % 2 == 0, i > 0 { a.source.delete("k\(i - 1)") }
            a.sync()
        }
        let c = makeReplica("C", hub: hub)
        settle([a, c])
        XCTAssertEqual(a.source.model, c.source.model)
    }

    func testRemoteApplyDoesNotClobberLocalEditMadeDuringHop() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T", "emoji": "E"])
        settle([a, b])
        b.source.deferApplies = true
        a.source.set("x", "title", "Remote")
        a.source.set("x", "emoji", "Remote emoji")
        a.sync()
        advance(1)
        b.sync()                         // merges remote; apply is queued (main-thread hop)
        b.source.set("x", "title", "Typed during hop")
        b.source.runPendingApplies()     // the hop lands
        XCTAssertEqual(b.source.model.items["x"]?["title"], "Typed during hop", "local edit survives")
        XCTAssertEqual(b.source.model.items["x"]?["emoji"], "Remote emoji", "untouched fields still apply")
        b.source.deferApplies = false
        settle([a, b])
        XCTAssertEqual(a.source.model, b.source.model)
        XCTAssertEqual(a.source.model.items["x"]?["title"], "Typed during hop")
    }

    func testUnabsorbableRemoteValueIsReportedNotFought() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        b.source.model.stubborn = ["x"]
        a.source.set("x", "title", "New")
        settle([a, b])
        XCTAssertEqual(b.source.model.items["x"]?["title"], "T")
        XCTAssertEqual(a.source.model.items["x"]?["title"], "New", "B must not write its stale value back")
        XCTAssertGreaterThan(b.engine.status.unappliedFields, 0)
        // Once it can absorb it, a later round catches up.
        b.source.model.stubborn = []
        settle([a, b])
        XCTAssertEqual(b.source.model.items["x"]?["title"], "New")
    }

    func testCustomMergePolicy() {
        // The toy's "counter" collection keeps the max of `n` whatever the clocks say.
        let hub = makeHub()
        let a = makeReplica("A", hub: hub)
        settle([a])
        var doc = SyncDocument()
        let spec = a.source.collections.first { $0.name == "counter" }!
        doc.merge(SyncOp(col: "counter", key: "k", f: "n", v: .number(7), c: HLC(millis: 1, counter: 0, device: "A")), policy: spec.policy)
        doc.merge(SyncOp(col: "counter", key: "k", f: "n", v: .number(2), c: HLC(millis: 2, counter: 0, device: "B")), policy: spec.policy)
        XCTAssertEqual(doc.value("counter", "k", "n"), .number(7))
    }

    func testRejoinAfterLocalDataWasWipedRestoresInsteadOfDeleting() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        a.source.insert("y", into: "L")
        settle([a, b])
        // B's local data is thrown away outside sync (e.g. windows not restored).
        b.source.model = ToySyncSource.Model()
        b.source.insert("fresh", into: "L")
        b.engine.rejoin(sourceID: "toy")
        settle([a, b])
        XCTAssertEqual(Set(a.source.model.items.keys), ["x", "y", "fresh"], "nothing deleted on A")
        XCTAssertEqual(a.source.model, b.source.model)
    }

    func testResetLocalStateRejoinsWithNewDeviceID() {
        let hub = makeHub()
        let a = makeReplica("A", hub: hub), b = makeReplica("B", hub: hub)
        a.source.insert("x", into: "L", fields: ["title": "T"])
        settle([a, b])
        let oldID = b.engine.deviceID
        b.engine.resetLocalState()
        settle([a, b])
        XCTAssertNotEqual(b.engine.deviceID, oldID)
        XCTAssertEqual(a.source.model, b.source.model)
    }

    func testEngineStatePersistsThroughFileStorage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileSyncEngineStorage(url: dir.appendingPathComponent("engine.json"))
        var state = SyncEngineState(deviceID: "D")
        state.doc.merge(SyncOp(col: "c", key: "k", f: "f", v: .string("v"), c: HLC(millis: 1, counter: 0, device: "D")), policy: LastWriterWins())
        state.cursor = ["E": 4]
        storage.save(state)
        XCTAssertEqual(storage.load(), state)
        try "garbage".write(to: dir.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(storage.load())
    }

    // MARK: - Fuzz

    func testRandomizedConvergenceWithLatency() {
        for seed in UInt64(1)...UInt64(60) {
            runFuzz(seed: seed, replicas: 3, steps: 60)
        }
    }

    private func runFuzz(seed: UInt64, replicas count: Int, steps: Int) {
        var rng = SeededRandom(seed: seed)
        let hub = makeHub(latency: 0...2, seed: seed)
        let rs = (0..<count).map { makeReplica("R\($0)", hub: hub) }
        var nextKey = 0
        for _ in 0..<steps {
            let r = rs.randomElement(using: &rng)!
            let keys = Array(r.source.model.items.keys).sorted()
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1, 2:
                nextKey += 1
                let parent = ["L", "M"].randomElement(using: &rng)!
                let idx = Int.random(in: 0...(r.source.model.lists[parent]?.count ?? 0), using: &rng)
                r.source.insert("k\(nextKey)", into: parent, at: idx, fields: ["v": "\(nextKey)"])
            case 3, 4, 5:
                if let k = keys.randomElement(using: &rng) {
                    r.source.set(k, ["v", "w"].randomElement(using: &rng)!, "\(Int.random(in: 0..<100, using: &rng))")
                }
            case 6:
                if let k = keys.randomElement(using: &rng) { r.source.delete(k) }
            case 7, 8:
                if let k = keys.randomElement(using: &rng), r.source.model.lists.values.contains(where: { $0.contains(k) }) {
                    let parent = ["L", "M"].randomElement(using: &rng)!
                    r.source.move(k, to: parent, at: Int.random(in: 0...(r.source.model.lists[parent]?.count ?? 0), using: &rng))
                }
            default:
                break
            }
            if Bool.random(using: &rng) { r.sync() }
            advance(Double.random(in: 0...0.7, using: &rng))
        }
        settle(rs, rounds: 8)
        for r in rs.dropFirst() {
            XCTAssertEqual(r.source.model.items, rs[0].source.model.items, "seed \(seed): items diverged")
            XCTAssertEqual(r.source.model.lists, rs[0].source.model.lists, "seed \(seed): lists diverged")
        }
        // Local state matches the merged document.
        let doc = rs[0].engine.state.doc
        XCTAssertEqual(Set(rs[0].source.model.items.keys), Set(doc.aliveKeys("item")), "seed \(seed)")
        for (parent, list) in rs[0].source.model.lists {
            XCTAssertEqual(list, doc.children("item", parent: parent), "seed \(seed)")
        }
    }
}

/// Mirrors HistorySyncSource: its own queue, `project` hops onto it
/// synchronously, `apply` runs on it and calls back from it.
final class QueueHoppingSource: SyncSource {
    let id = "hop"
    let q = Queue.create(label: "HopSourceQueue")
    var items: [String: String] = ["a": "1"]
    var collections: [SyncCollectionSpec] { [SyncCollectionSpec(name: "hop")] }
    var localChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func project() -> SyncProjection? {
        var p = SyncProjection()
        q.runSync { for (k, v) in items { p["hop", k] = ["v": .string(v)] } }
        p.declare("hop")
        return p
    }
    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        q.run { completion() }
    }
}

final class SyncEngineThreadingTests: XCTestCase {
    func testJoinWithSourceThatCallsBackFromItsOwnQueue() {
        let hub = InMemorySyncHub()
        let engine = SyncEngine(sources: [QueueHoppingSource()], transport: hub.transport(device: "A"), storage: InMemorySyncEngineStorage(state: SyncEngineState(deviceID: "A")), deviceName: "A", throttle: 0)
        engine.start()
        defer { engine.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !engine.status.joinedSources.contains("hop"), Date() < deadline {
            engine.scheduleTick()
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(engine.status.joinedSources.contains("hop"), "join finished without deadlocking")
        engine.runUntilQuiet()
        XCTAssertEqual(hub.batches(from: "A").flatMap(\.ops).first { $0.f == "v" }?.v, .string("1"))
    }
}
