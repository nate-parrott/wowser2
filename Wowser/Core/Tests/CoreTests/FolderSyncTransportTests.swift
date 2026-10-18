import XCTest
@testable import Core

final class FolderSyncTransportTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func transport(_ device: String, maxBatches: Int = 500, delay: ClosedRange<TimeInterval>? = nil) -> FolderSyncTransport {
        FolderSyncTransport(root: dir, deviceID: device, coordinated: false, pollInterval: 0.05, writeDelay: delay, maxBatchesPerFile: maxBatches)
    }

    private func batch(_ device: String, _ seq: Int, _ value: String = "v") -> SyncBatch {
        SyncBatch(device: device, deviceName: device, seq: seq, createdAt: Date(), ops: [
            SyncOp(col: "c", key: "k\(seq)", f: "f", v: .string(value), c: HLC(millis: Int64(seq), counter: 0, device: device))
        ])
    }

    func testPublishAndFetchAcrossDevices() throws {
        let a = transport("A"), b = transport("B")
        try a.publish(batch("A", 1)) { self.batch("A", 1, "snapshot") }
        try a.publish(batch("A", 2)) { XCTFail("no roll expected"); return self.batch("A", 2) }
        let got = try b.fetch(after: [:])
        XCTAssertEqual(got.map(\.seq), [1, 2])
        XCTAssertEqual(got.first?.ops.first?.v, .string("snapshot"), "a device's first file starts with a snapshot")
        XCTAssertTrue(try a.fetch(after: [:]).isEmpty, "own log isn't fetched")
        // Incremental: only new lines are returned.
        XCTAssertTrue(try b.fetch(after: ["A": 2]).isEmpty)
        try a.publish(batch("A", 3)) { self.batch("A", 3) }
        XCTAssertEqual(try b.fetch(after: ["A": 2]).map(\.seq), [3])
    }

    func testIgnoresPartialTrailingLineUntilComplete() throws {
        let a = transport("A"), b = transport("B")
        try a.publish(batch("A", 1)) { self.batch("A", 1) }
        let url = dir.appendingPathComponent("v1/devices/A/log-000001.jsonl")
        var line = try JSONEncoder().encode(batch("A", 2))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(10))
        XCTAssertEqual(try b.fetch(after: [:]).map(\.seq), [1])
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line.dropFirst(10))
        try handle.close()
        XCTAssertEqual(try b.fetch(after: ["A": 1]).map(\.seq), [2])
    }

    func testRollsToSnapshotGenerationAndDeletesOld() throws {
        let a = transport("A", maxBatches: 3), b = transport("B")
        for seq in 1...7 {
            try a.publish(batch("A", seq)) { SyncBatch(device: "A", deviceName: nil, seq: seq, createdAt: Date(), snapshot: true, ops: []) }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("v1/devices/A").path)
        XCTAssertEqual(files.filter { $0.hasPrefix("log-") }.count, 1, "old generations are deleted")
        let got = try b.fetch(after: [:])
        XCTAssertEqual(got.first?.snapshot, true)
        XCTAssertEqual(got.map(\.seq), [7], "gen 3 = snapshot(7)")
    }

    func testReopeningTransportContinuesCurrentGeneration() throws {
        do {
            let a = transport("A", maxBatches: 3)
            try a.publish(batch("A", 1)) { self.batch("A", 1) }
            try a.publish(batch("A", 2)) { self.batch("A", 2) }
        }
        let a2 = transport("A", maxBatches: 3)
        var rolled = false
        try a2.publish(batch("A", 3)) { rolled = true; return self.batch("A", 3) }
        XCTAssertFalse(rolled, "picks up the existing file's line count")
        try a2.publish(batch("A", 4)) { rolled = true; return self.batch("A", 4) }
        XCTAssertTrue(rolled)
    }

    func testMissingFolderIsAnError() {
        let t = FolderSyncTransport(root: dir.appendingPathComponent("nope"), deviceID: "A", coordinated: false, pollInterval: 1)
        XCTAssertThrowsError(try t.fetch(after: [:]))
    }

    func testPollingNotifiesOnRemoteWrite() throws {
        let a = transport("A"), b = transport("B")
        let exp = expectation(description: "notified")
        exp.assertForOverFulfill = false
        b.onRemoteChange = { exp.fulfill() }
        b.start()
        defer { b.stop() }
        try a.publish(batch("A", 1)) { self.batch("A", 1) }
        wait(for: [exp], timeout: 2)
    }

    func testDelayedWritesKeepOrderAndArriveEventually() throws {
        let a = transport("A", delay: 0...0.15), b = transport("B")
        for seq in 1...10 { try a.publish(batch("A", seq)) { self.batch("A", seq) } }
        var seen = [Int]()
        let deadline = Date().addingTimeInterval(5)
        while seen.count < 10, Date() < deadline {
            seen += try b.fetch(after: ["A": seen.last ?? 0]).map(\.seq)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(seen, Array(1...10))
    }

    /// End to end: two engines syncing through a real folder, with latency.
    func testEnginesConvergeThroughFolder() throws {
        let sa = ToySyncSource(), sb = ToySyncSource()
        let ea = SyncEngine(sources: [sa], transport: transport("A", maxBatches: 4, delay: 0...0.05), storage: InMemorySyncEngineStorage(state: SyncEngineState(deviceID: "A")), deviceName: "A", throttle: 0)
        let eb = SyncEngine(sources: [sb], transport: transport("B", maxBatches: 4), storage: InMemorySyncEngineStorage(state: SyncEngineState(deviceID: "B")), deviceName: "B", throttle: 0)
        func settle() {
            for _ in 0..<15 {
                ea.runUntilQuiet(); eb.runUntilQuiet()
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        settle()
        for i in 0..<12 { sa.insert("a\(i)", into: "L", fields: ["n": "\(i)"]); ea.runUntilQuiet() }
        sb.insert("b0", into: "L", at: 0)
        settle()
        sb.move("a11", to: "L", at: 0)
        sa.delete("a3")
        settle()
        XCTAssertEqual(sa.model, sb.model)
        XCTAssertEqual(sa.model.lists["L"]?.first, "a11")
        XCTAssertNil(sb.model.items["a3"])
    }
}
