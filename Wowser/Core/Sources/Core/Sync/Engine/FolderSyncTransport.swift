import Foundation

/// Syncs through a shared folder: an iCloud Drive folder in the app, a plain
/// temp folder in tests and the two-instance harness.
///
/// Layout (one writer per file, so file-sync conflicts can't happen):
///
///     <root>/v1/devices/<deviceID>/log-000001.jsonl
///
/// Each line is one JSON `SyncBatch`. A device appends to its newest log
/// file; when that gets big it starts the next generation with a snapshot
/// batch (its whole merged document) and deletes the old ones. Readers only
/// ever need a device's newest generation: the snapshot at its head covers
/// everything before it.
public final class FolderSyncTransport: SyncTransport {
    public let root: URL
    public let deviceID: String
    /// Use NSFileCoordinator (iCloud Drive) for reads and writes.
    let coordinated: Bool
    let pollInterval: TimeInterval
    /// Test harness: delay each write by a random amount in this range (keeps
    /// order), to simulate a slow sync service.
    let writeDelay: ClosedRange<TimeInterval>?
    let maxBatchesPerFile: Int
    let maxBytesPerFile: Int

    public var onRemoteChange: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "FolderSyncTransport.io", qos: .utility)
    private let lock = NSLock()
    /// Own log: current generation and how much is in it (incl. delayed writes).
    private var ownGeneration = 0
    private var ownBatchCount = 0
    private var ownBytes = 0
    private var lastScheduledWrite = Date.distantPast
    /// Read progress per remote file path.
    private var readOffsets: [String: UInt64] = [:]
    private var lastPollSignature: [String: String] = [:]
    private var timer: DispatchSourceTimer?

    public init(root: URL, deviceID: String, coordinated: Bool, pollInterval: TimeInterval, writeDelay: ClosedRange<TimeInterval>? = nil, maxBatchesPerFile: Int = 500, maxBytesPerFile: Int = 4_000_000) {
        self.root = root
        self.deviceID = deviceID
        self.coordinated = coordinated
        self.pollInterval = pollInterval
        self.writeDelay = writeDelay
        self.maxBatchesPerFile = maxBatchesPerFile
        self.maxBytesPerFile = maxBytesPerFile
        scanOwnLog()
    }

    var devicesDir: URL { root.appendingPathComponent("v1").appendingPathComponent("devices") }
    var ownDir: URL { devicesDir.appendingPathComponent(deviceID) }

    static func logFileName(generation: Int) -> String {
        String(format: "log-%06d.jsonl", generation)
    }

    static func generation(ofLogFile name: String) -> Int? {
        guard name.hasPrefix("log-"), name.hasSuffix(".jsonl") else { return nil }
        return Int(name.dropFirst(4).dropLast(6))
    }

    public var debugDescription: String {
        "Folder: \(root.path)" + (writeDelay.map { " (simulated latency \($0.lowerBound)–\($0.upperBound)s)" } ?? "")
    }

    // MARK: - Writing

    private func scanOwnLog() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ownDir.path)) ?? []
        let gen = files.compactMap(Self.generation(ofLogFile:)).max() ?? 0
        ownGeneration = gen
        if gen > 0, let data = try? Data(contentsOf: ownDir.appendingPathComponent(Self.logFileName(generation: gen))) {
            ownBytes = data.count
            ownBatchCount = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        }
    }

    public func publish(_ batch: SyncBatch, snapshot: () -> SyncBatch) throws {
        let roll = lock.withLock { ownGeneration == 0 || ownBatchCount >= maxBatchesPerFile || ownBytes >= maxBytesPerFile }
        let toWrite = roll ? snapshot() : batch
        var line = try JSONEncoder().encode(toWrite)
        line.append(UInt8(ascii: "\n"))

        let generation: Int = lock.withLock {
            if roll {
                ownGeneration += 1
                ownBatchCount = 0
                ownBytes = 0
            }
            ownBatchCount += 1
            ownBytes += line.count
            return ownGeneration
        }

        if let writeDelay {
            let due: Date = lock.withLock {
                let d = max(lastScheduledWrite, Date().addingTimeInterval(Double.random(in: writeDelay)))
                lastScheduledWrite = d
                return d
            }
            ioQueue.async { self.delayed.append((due, line, generation, roll)) }
            ioQueue.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) { [weak self] in
                self?.drainDelayedWrites()
            }
        } else {
            try ioQueue.sync { try write(line: line, generation: generation, startsGeneration: roll) }
        }
    }

    /// Writes whose delay has elapsed, oldest first (dues never decrease, so
    /// this preserves publish order). Only touched on `ioQueue`.
    private var delayed: [(due: Date, line: Data, generation: Int, roll: Bool)] = []

    private func drainDelayedWrites() {
        while let next = delayed.first, next.due <= Date().addingTimeInterval(0.001) {
            delayed.removeFirst()
            do { try write(line: next.line, generation: next.generation, startsGeneration: next.roll) }
            catch { print("[Sync] Delayed write failed: \(error)") }
        }
    }

    private func write(line: Data, generation: Int, startsGeneration: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ownDir, withIntermediateDirectories: true)
        let url = ownDir.appendingPathComponent(Self.logFileName(generation: generation))
        try coordinate(writing: url) { url in
            if startsGeneration || !fm.fileExists(atPath: url.path) {
                try line.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        }
        if startsGeneration {
            // The snapshot supersedes older generations.
            for name in (try? fm.contentsOfDirectory(atPath: ownDir.path)) ?? [] {
                if let g = Self.generation(ofLogFile: name), g < generation {
                    try? coordinate(writing: ownDir.appendingPathComponent(name)) { try fm.removeItem(at: $0) }
                }
            }
        }
    }

    // MARK: - Reading

    public func fetch(after cursor: [String: Int]) throws -> [SyncBatch] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw SyncTransportError.unavailable("Sync folder missing: \(root.path)")
        }
        try? fm.createDirectory(at: devicesDir, withIntermediateDirectories: true)
        var out = [SyncBatch]()
        var livePaths = Set<String>()
        for device in try fm.contentsOfDirectory(atPath: devicesDir.path) where device != deviceID && !device.hasPrefix(".") {
            let dir = devicesDir.appendingPathComponent(device)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            requestDownloads(in: dir, names: names)
            guard let newest = names.compactMap(Self.generation(ofLogFile:)).max() else { continue }
            let url = dir.appendingPathComponent(Self.logFileName(generation: newest))
            livePaths.insert(url.path)
            out += readNewLines(url, minSeq: cursor[device] ?? 0)
        }
        lock.withLock { readOffsets = readOffsets.filter { livePaths.contains($0.key) } }
        return out
    }

    /// Batches in `url` past what we've read before (complete lines only).
    private func readNewLines(_ url: URL, minSeq: Int) -> [SyncBatch] {
        var offset = lock.withLock { readOffsets[url.path] ?? 0 }
        var data = Data()
        try? coordinate(reading: url) { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset { offset = 0 } // rewritten
            guard size > offset else { return }
            try? handle.seek(toOffset: offset)
            data = (try? handle.readToEnd()) ?? Data()
        }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        lock.withLock { readOffsets[url.path] = offset + UInt64(complete.count) }
        let decoder = JSONDecoder()
        return complete.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let batch = try? decoder.decode(SyncBatch.self, from: Data(line)) else {
                print("[Sync] Skipping unreadable line in \(url.lastPathComponent)")
                return nil
            }
            return batch.seq > minSeq ? batch : nil
        }
    }

    /// Old-style iCloud placeholders (".name.icloud"): ask for the real file.
    private func requestDownloads(in dir: URL, names: [String]) {
        guard coordinated else { return }
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let real = dir.appendingPathComponent(String(name.dropFirst().dropLast(7)))
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
    }

    // MARK: - Watching

    public func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(Int(pollInterval * 100)))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Cheap change check: sizes + mtimes of other devices' files.
    private func poll() {
        let fm = FileManager.default
        var sig = [String: String]()
        for device in (try? fm.contentsOfDirectory(atPath: devicesDir.path)) ?? [] where device != deviceID {
            let dir = devicesDir.appendingPathComponent(device)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let path = dir.appendingPathComponent(name).path
                let attrs = try? fm.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                sig[path] = "\(size)|\(mtime)"
            }
        }
        let changed = lock.withLock { () -> Bool in
            defer { lastPollSignature = sig }
            return sig != lastPollSignature
        }
        if changed { onRemoteChange?() }
    }

    // MARK: - Coordination

    private func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        guard coordinated else { return try body(url) }
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }

    private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        guard coordinated else { return try body(url) }
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }
}
