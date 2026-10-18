import XCTest
@testable import Core

/// HLC, fractional indexing, order-key assignment, document merge laws, diff.
final class SyncPrimitivesTests: XCTestCase {

    // MARK: - Values

    func testSyncValueJSONKeepsBoolsAndNumbersApart() throws {
        let json = #"[true, 1, 0, 1.5, "x", null, {"a": [false, 2]}]"#
        let v = try JSONDecoder().decode(SyncValue.self, from: Data(json.utf8))
        XCTAssertEqual(v, .array([.bool(true), .number(1), .number(0), .number(1.5), .string("x"), .null, .object(["a": .array([.bool(false), .number(2)])])]))
        let again = try JSONDecoder().decode(SyncValue.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(again, v)
    }

    func testCodableRoundTripThroughSyncValue() {
        let theme = SpaceTheme(hue: 214, secondaryHue: 236.5)
        let v = SyncValue.encoding(theme)
        XCTAssertEqual(v.decoded(as: SpaceTheme.self), theme)
        XCTAssertEqual(SyncValue.encoding(v.decoded(as: SpaceTheme.self)), v, "stable, so it doesn't look changed every round")
        let d = Date()
        XCTAssertEqual(SyncValue(d).dateValue, d)
    }

    // MARK: - HLC

    func testHLCOrdersByMillisThenCounterThenDevice() {
        let a = HLC(millis: 1, counter: 5, device: "z")
        let b = HLC(millis: 2, counter: 0, device: "a")
        let c = HLC(millis: 2, counter: 1, device: "a")
        let d = HLC(millis: 2, counter: 1, device: "b")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertLessThan(c, d)
    }

    func testHLCRoundTripsThroughCompactString() throws {
        let clock = HLC(millis: 1_700_000_000_123, counter: 42, device: "8F2C-DEV")
        let data = try JSONEncoder().encode(clock)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"1700000000123.42@8F2C-DEV\"")
        XCTAssertEqual(try JSONDecoder().decode(HLC.self, from: data), clock)
        XCTAssertNil(HLC(string: "nonsense"))
    }

    func testClockIsMonotonicEvenWhenWallClockStallsOrGoesBack() {
        var clock = HLCClock(device: "a")
        let t0 = Date(timeIntervalSince1970: 1000)
        let c1 = clock.tick(now: t0)
        let c2 = clock.tick(now: t0)
        let c3 = clock.tick(now: t0.addingTimeInterval(-50))
        XCTAssertLessThan(c1, c2)
        XCTAssertLessThan(c2, c3)
    }

    func testClockObservesRemoteAheadOfUs() {
        var clock = HLCClock(device: "a")
        let remote = HLC(millis: 9_000_000, counter: 3, device: "b")
        clock.observe(remote)
        let next = clock.tick(now: Date(timeIntervalSince1970: 1))
        XCTAssertGreaterThan(next, remote, "a device whose clock is behind must still write after what it has seen")
    }

    // MARK: - Fractional index

    func testKeyBetweenIsStrictlyBetween() {
        let cases: [(String?, String?)] = [(nil, nil), (nil, "V"), ("V", nil), ("A", "B"), ("A", "A1"), ("Az", "B"), ("1", "2"), (nil, "01"), ("zz", nil), ("V", "V01")]
        for (a, b) in cases {
            let k = FractionalIndex.key(between: a, and: b)
            XCTAssertTrue(FractionalIndex.isValid(k), "\(k) invalid for \(String(describing: a))..\(String(describing: b))")
            if let a { XCTAssertGreaterThan(k, a) }
            if let b { XCTAssertLessThan(k, b) }
        }
    }

    func testRepeatedInsertionAtFrontAndBackAndMiddleStaysOrdered() {
        var keys = [FractionalIndex.key(between: nil, and: nil)]
        var rng = SeededRandom(seed: 7)
        for _ in 0..<2000 {
            let i = Int.random(in: 0...keys.count, using: &rng)
            let k = FractionalIndex.key(between: i == 0 ? nil : keys[i - 1], and: i == keys.count ? nil : keys[i])
            keys.insert(k, at: i)
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThan(keys.map(\.count).max()!, 40, "keys should stay short under random inserts")
    }

    func testAppendingManyKeepsKeysShort() {
        var last: String? = nil
        for _ in 0..<1000 {
            let k = FractionalIndex.key(between: last, and: nil)
            if let last { XCTAssertGreaterThan(k, last) }
            last = k
        }
        XCTAssertLessThan(last!.count, 20)
    }

    func testKeysBetweenCount() {
        let ks = FractionalIndex.keys(between: "A", and: "B", count: 25)
        XCTAssertEqual(ks.count, 25)
        XCTAssertEqual(ks, ks.sorted())
        XCTAssertTrue(ks.allSatisfy { $0 > "A" && $0 < "B" })
    }

    func testInvalidBoundsStillYieldUsableKey() {
        XCTAssertTrue(FractionalIndex.isValid(FractionalIndex.key(between: "B", and: "A")))
        XCTAssertTrue(FractionalIndex.isValid(FractionalIndex.key(between: "A0", and: "!!")))
        XCTAssertGreaterThan(FractionalIndex.key(between: "B", and: "B"), "B")
    }

    // MARK: - Order key assignment

    private func materialize(_ keys: [String: String]) -> [String] {
        keys.map { OrderSortKey(order: $0.value, id: $0.key) }.sorted().map(\.id)
    }

    func testAssignKeysKeepsKeysForUnmovedItems() {
        let existing = ["a": "A", "b": "B", "c": "C", "d": "D"]
        // Move d to the front.
        let out = SyncOrdering.assignKeys(items: ["d", "a", "b", "c"], existing: existing)
        XCTAssertEqual(out["a"], "A")
        XCTAssertEqual(out["b"], "B")
        XCTAssertEqual(out["c"], "C")
        XCTAssertNotEqual(out["d"], "D", "only the moved item is re-keyed")
        XCTAssertEqual(materialize(out), ["d", "a", "b", "c"])
    }

    func testAssignKeysForNewItemsAndReversal() {
        let out = SyncOrdering.assignKeys(items: ["x", "c", "b", "y", "a"], existing: ["a": "A", "b": "B", "c": "C"])
        XCTAssertEqual(materialize(out), ["x", "c", "b", "y", "a"])
        XCTAssertEqual(out.values.filter { ["A", "B", "C"].contains($0) }.count, 1, "reversal keeps exactly one key")
    }

    func testAssignKeysWithTiedExistingKeys() {
        // Concurrent inserts can mint the same key; ties sort by id.
        let existing = ["a": "M", "b": "M", "c": "M"]
        let out = SyncOrdering.assignKeys(items: ["a", "new", "b", "c"], existing: existing)
        XCTAssertEqual(materialize(out), ["a", "new", "b", "c"])
    }

    func testAssignKeysRandomized() {
        var rng = SeededRandom(seed: 99)
        for _ in 0..<300 {
            let n = Int.random(in: 0...12, using: &rng)
            var existing = [String: String]()
            var keys = FractionalIndex.keys(between: nil, and: nil, count: n)
            if Bool.random(using: &rng), n > 1 { keys[1] = keys[0] } // a tie
            for i in 0..<n where Bool.random(using: &rng) { existing["i\(i)"] = keys[i] }
            let items = (0..<n).map { "i\($0)" }.shuffled(using: &rng) + ["new1", "new2"].prefix(Int.random(in: 0...2, using: &rng))
            let out = SyncOrdering.assignKeys(items: Array(items), existing: existing)
            XCTAssertEqual(materialize(out), Array(items))
        }
    }

    // MARK: - Document merge laws

    private func randomOps(count: Int, rng: inout SeededRandom) -> [SyncOp] {
        (0..<count).map { i in
            let device = ["a", "b", "c"].randomElement(using: &rng)!
            return SyncOp(
                col: ["x", "y"].randomElement(using: &rng)!,
                key: "k\(Int.random(in: 0..<4, using: &rng))",
                f: ["f", "g", SyncReservedField.deleted, "n"].randomElement(using: &rng)!,
                v: [.string("1"), .string("2"), .bool(true), .bool(false), .number(Double(Int.random(in: 0..<5, using: &rng))), .null].randomElement(using: &rng)!,
                c: HLC(millis: Int64.random(in: 0..<20, using: &rng), counter: Int32(i % 3), device: device))
        }
    }

    private struct Policies: SyncMergePolicy {
        let inner = FieldMergePolicy(["n": FieldMergePolicy.maxNumber])
        func merge(field: String, current: SyncField, incoming: SyncField) -> SyncField {
            inner.merge(field: field, current: current, incoming: incoming)
        }
    }

    func testMergeIsOrderIndependentAndIdempotent() {
        var rng = SeededRandom(seed: 1)
        for _ in 0..<200 {
            let ops = randomOps(count: 30, rng: &rng)
            var d1 = SyncDocument(), d2 = SyncDocument(), d3 = SyncDocument()
            for op in ops { d1.merge(op, policy: Policies()) }
            for op in ops.shuffled(using: &rng) { d2.merge(op, policy: Policies()) }
            for op in (ops + ops.shuffled(using: &rng)).shuffled(using: &rng) { d3.merge(op, policy: Policies()) }
            XCTAssertEqual(d1, d2)
            XCTAssertEqual(d1, d3)
        }
    }

    func testAllOpsReproducesDocument() {
        var rng = SeededRandom(seed: 2)
        var doc = SyncDocument()
        for op in randomOps(count: 100, rng: &rng) { doc.merge(op, policy: LastWriterWins()) }
        var copy = SyncDocument()
        for op in doc.allOps() { copy.merge(op, policy: LastWriterWins()) }
        XCTAssertEqual(copy, doc)
    }

    func testMaxNumberPolicyKeepsLargestRegardlessOfClock() {
        var doc = SyncDocument()
        let policy = FieldMergePolicy(["n": FieldMergePolicy.maxNumber])
        doc.merge(SyncOp(col: "c", key: "k", f: "n", v: .number(10), c: HLC(millis: 1, counter: 0, device: "a")), policy: policy)
        doc.merge(SyncOp(col: "c", key: "k", f: "n", v: .number(3), c: HLC(millis: 9, counter: 0, device: "b")), policy: policy)
        XCTAssertEqual(doc.value("c", "k", "n"), .number(10))
        // Reserved fields always use clock order.
        doc.merge(SyncOp(col: "c", key: "k", f: SyncReservedField.deleted, v: .bool(true), c: HLC(millis: 9, counter: 0, device: "b")), policy: policy)
        doc.merge(SyncOp(col: "c", key: "k", f: SyncReservedField.deleted, v: .bool(false), c: HLC(millis: 1, counter: 0, device: "a")), policy: policy)
        XCTAssertTrue(doc.isDeleted("c", "k"))
    }

    func testMergeReportsVisibleChangesOnly() {
        var doc = SyncDocument()
        let op = SyncOp(col: "c", key: "k", f: "f", v: .string("x"), c: HLC(millis: 1, counter: 0, device: "a"))
        XCTAssertEqual(doc.merge(op, policy: LastWriterWins()), .changed(previous: nil))
        XCTAssertEqual(doc.merge(op, policy: LastWriterWins()), .unchanged)
        var newer = op
        newer.c.millis = 2
        XCTAssertEqual(doc.merge(newer, policy: LastWriterWins()), .unchanged, "same value, newer clock: not a visible change")
        var older = op
        older.c.millis = 0
        older.v = .string("old")
        XCTAssertEqual(doc.merge(older, policy: LastWriterWins()), .unchanged)
        XCTAssertEqual(doc.value("c", "k", "f"), .string("x"))
    }

    func testChildrenSortByOrderThenId() {
        var doc = SyncDocument()
        func set(_ key: String, _ f: String, _ v: SyncValue) {
            doc.merge(SyncOp(col: "t", key: key, f: f, v: v, c: HLC(millis: 1, counter: 0, device: "a")), policy: LastWriterWins())
        }
        set("b", "_parent", .string("p")); set("b", "_order", .string("M"))
        set("a", "_parent", .string("p")); set("a", "_order", .string("M"))
        set("c", "_parent", .string("p")); set("c", "_order", .string("A"))
        set("d", "_parent", .string("q")); set("d", "_order", .string("A"))
        set("e", "_parent", .string("p")); set("e", "_order", .string("B")); set("e", "_del", .bool(true))
        XCTAssertEqual(doc.children("t", parent: "p"), ["c", "a", "b"])
    }

    // MARK: - Diff

    private let specs: [String: SyncCollectionSpec] = [
        "item": SyncCollectionSpec(name: "item"),
        "row": SyncCollectionSpec(name: "row", ordered: true),
        "visit": SyncCollectionSpec(name: "visit", growOnly: true),
    ]

    private func apply(_ writes: [SyncDiff.Write], to doc: inout SyncDocument, device: String = "me", at millis: Int64 = 10) {
        for (i, w) in writes.enumerated() {
            doc.merge(SyncOp(col: w.col, key: w.key, f: w.f, v: w.v, c: HLC(millis: millis, counter: Int32(i), device: device)), policy: LastWriterWins())
        }
    }

    func testDiffCreateUpdateDelete() {
        var doc = SyncDocument()
        var p = SyncProjection()
        p["item", "a"] = ["title": .string("A")]
        var (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        XCTAssertEqual(writes.map(\.description), ["item/a._del=bool(false)", "item/a.title=string(\"A\")"])
        apply(writes, to: &doc)

        // No change → no writes.
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertTrue(writes.isEmpty)

        p["item", "a"] = ["title": .string("B")]
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertEqual(writes.map(\.description), ["item/a.title=string(\"B\")"])
        apply(writes, to: &doc, at: 11)

        // Clearing a field writes null.
        p["item", "a"] = [:]
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertEqual(writes.map(\.description), ["item/a.title=null"])
        apply(writes, to: &doc, at: 12)

        p.records["item"] = [:]
        (writes, _) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertEqual(writes.map(\.description), ["item/a._del=bool(true)"])
    }

    func testDiffNeverRevertsRemoteValueFromStaleLocalSnapshot() {
        var doc = SyncDocument()
        var p = SyncProjection()
        p["item", "a"] = ["title": .string("A")]
        var (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        apply(writes, to: &doc)
        // Remote changes the title; local hasn't applied it yet.
        doc.merge(SyncOp(col: "item", key: "a", f: "title", v: .string("Remote"), c: HLC(millis: 50, counter: 0, device: "other")), policy: LastWriterWins())
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertTrue(writes.isEmpty, "stale local value must not be written back")
        // Local applies the remote value: no echo.
        p["item", "a"] = ["title": .string("Remote")]
        (writes, _) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertTrue(writes.isEmpty)
    }

    func testDiffSkipsCollectionsMissingFromProjection() {
        var doc = SyncDocument()
        var p = SyncProjection()
        p["item", "a"] = ["title": .string("A")]
        let (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        apply(writes, to: &doc)
        let (w2, prev2) = SyncDiff.diff(specs: specs, projection: SyncProjection(), previous: prev, doc: doc)
        XCTAssertTrue(w2.isEmpty, "a collection the source didn't vouch for is unknown, not empty")
        XCTAssertEqual(prev2, prev)
    }

    func testDiffGrowOnlyNeverDeletes() {
        var doc = SyncDocument()
        var p = SyncProjection()
        p["visit", "v"] = ["n": .number(1)]
        let (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        apply(writes, to: &doc)
        p.records["visit"] = [:]
        XCTAssertTrue(SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc).writes.isEmpty)
    }

    func testDiffRevivesTombstonedRecordUnseenLocally() {
        var doc = SyncDocument()
        doc.merge(SyncOp(col: "item", key: "p0", f: "_del", v: .bool(true), c: HLC(millis: 1, counter: 0, device: "x")), policy: LastWriterWins())
        var p = SyncProjection()
        p["item", "p0"] = ["title": .string("Home")]
        let (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        XCTAssertEqual(writes.map(\.description), ["item/p0._del=bool(false)", "item/p0.title=string(\"Home\")"])
        // Once seen, a tombstone means "delete pending locally", not revive.
        XCTAssertTrue(SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc).writes.isEmpty)
    }

    func testDiffOrderedListOnlyRekeysMovedItems() {
        var doc = SyncDocument()
        var p = SyncProjection()
        for k in ["a", "b", "c", "d"] {
            p["row", k] = [:]
            p.append(k, to: "L", in: "row")
        }
        var (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        apply(writes, to: &doc)
        XCTAssertEqual(doc.children("row", parent: "L"), ["a", "b", "c", "d"])

        p.lists["row"]!["L"] = ["d", "a", "b", "c"]
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertEqual(writes.map(\.key), ["d"], "moving one item writes one order key")
        apply(writes, to: &doc, at: 11)
        XCTAssertEqual(doc.children("row", parent: "L"), ["d", "a", "b", "c"])

        // Move b to another list.
        p.lists["row"]!["L"] = ["d", "a", "c"]
        p.lists["row"]!["M"] = ["b"]
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertEqual(Set(writes.map(\.key)), ["b"])
        apply(writes, to: &doc, at: 12)
        XCTAssertEqual(doc.children("row", parent: "L"), ["d", "a", "c"])
        XCTAssertEqual(doc.children("row", parent: "M"), ["b"])
    }

    func testDiffUnchangedListDoesNotOverwriteRemoteReorder() {
        var doc = SyncDocument()
        var p = SyncProjection()
        for k in ["a", "b", "c"] { p["row", k] = [:]; p.append(k, to: "L", in: "row") }
        var (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: SyncProjection(), doc: doc)
        apply(writes, to: &doc)
        // Remote moves c to the front.
        let front = FractionalIndex.key(between: nil, and: doc.value("row", "a", "_order").stringValue)
        doc.merge(SyncOp(col: "row", key: "c", f: "_order", v: .string(front), c: HLC(millis: 99, counter: 0, device: "o")), policy: LastWriterWins())
        (writes, prev) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertTrue(writes.isEmpty)
        // Local applies it: still nothing to write.
        p.lists["row"]!["L"] = ["c", "a", "b"]
        (writes, _) = SyncDiff.diff(specs: specs, projection: p, previous: prev, doc: doc)
        XCTAssertTrue(writes.isEmpty, "\(writes)")
    }

    // MARK: - Update helpers

    func testFieldsToApplyRespectsLocalEditsSinceLastLook() {
        var doc = SyncDocument()
        for (f, v) in [("title", "Remote"), ("emoji", "🐙")] {
            doc.merge(SyncOp(col: "item", key: "a", f: f, v: .string(v), c: HLC(millis: 5, counter: 0, device: "o")), policy: LastWriterWins())
        }
        var expected = SyncProjection()
        expected["item", "a"] = ["title": .string("Old"), "emoji": .string("🙂")]
        let update = SyncUpdate(doc: doc, changed: ["item": ["a"]], changedParents: [:], expected: expected)
        // User edited the title locally after the engine looked; emoji untouched.
        let out = update.fieldsToApply("item", "a", current: ["title": .string("Typed"), "emoji": .string("🙂")])
        XCTAssertEqual(out, ["emoji": .string("🐙")])
        // A record the source doesn't have gets everything.
        XCTAssertEqual(update.fieldsToApply("item", "a", current: nil), ["title": .string("Remote"), "emoji": .string("🐙")])
    }

    func testDesiredOrderKeepsLocalOnlyItemsAndChecksForLocalReorder() {
        var doc = SyncDocument()
        for (k, o) in [("b", "A"), ("a", "B"), ("c", "C")] {
            doc.merge(SyncOp(col: "row", key: k, f: "_parent", v: .string("L"), c: HLC(millis: 1, counter: 0, device: "o")), policy: LastWriterWins())
            doc.merge(SyncOp(col: "row", key: k, f: "_order", v: .string(o), c: HLC(millis: 1, counter: 0, device: "o")), policy: LastWriterWins())
        }
        var expected = SyncProjection()
        expected.lists["row"] = ["L": ["a", "b"]]
        let update = SyncUpdate(doc: doc, changed: [:], changedParents: ["row": ["L"]], expected: expected)
        XCTAssertEqual(update.desiredOrder("row", parent: "L", local: ["a", "new", "b"]), ["b", "new", "a", "c"])
        XCTAssertNil(update.desiredOrder("row", parent: "L", local: ["b", "a"]), "user reordered locally since the engine looked")
        let joining = SyncUpdate(doc: doc, changed: [:], changedParents: ["row": ["L"]], expected: SyncProjection())
        XCTAssertNil(joining.desiredOrder("row", parent: "L", local: ["b", "a", "c"]), "already in doc order")
        XCTAssertEqual(joining.desiredOrder("row", parent: "L", local: ["c", "mine", "a"]), ["b", "mine", "a", "c"])
    }
}
