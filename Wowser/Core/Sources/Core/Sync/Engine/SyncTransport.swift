import Foundation

/// Moves log batches between devices. The engine calls these on its own
/// serial queue, synchronously; implementations can block on I/O.
///
/// Transports only need to be dumb, eventually consistent byte pipes: every
/// batch a device publishes should eventually reach every other device, but
/// duplicates, delays and re-deliveries are fine (merging is idempotent and
/// the engine skips batches at or below its per-device cursor).
public protocol SyncTransport: AnyObject {
    /// Append one of this device's batches. `snapshot` builds a batch holding
    /// the whole merged document; a transport may write that instead (when it
    /// rolls its log over to bound its size).
    func publish(_ batch: SyncBatch, snapshot: () -> SyncBatch) throws
    /// Other devices' batches the engine may not have seen. `cursor` is the
    /// highest seq already merged per device; returning older ones is allowed.
    func fetch(after cursor: [String: Int]) throws -> [SyncBatch]
    /// Called (on any thread) when new remote data may be available.
    var onRemoteChange: (() -> Void)? { get set }
    /// Start/stop background watching (polling, file presenters…).
    func start()
    func stop()
    /// Shown in the sync settings' debug section.
    var debugDescription: String { get }
}

public extension SyncTransport {
    func start() {}
    func stop() {}
}

// MARK: - In-memory (tests)

/// A shared "server" for in-process replicas. Each published batch becomes
/// visible to others after a random delay drawn from `latency`, while keeping
/// each device's batches in order (like an append-only file that syncs late).
public final class InMemorySyncHub {
    public var now: () -> Date
    public var latency: ClosedRange<TimeInterval>
    private var rng: SeededRandom
    private let lock = NSLock()
    private var logs: [String: [(batch: SyncBatch, visibleAt: Date)]] = [:]
    private var transports = NSHashTable<InMemorySyncTransport>.weakObjects()

    public init(latency: ClosedRange<TimeInterval> = 0...0, seed: UInt64? = nil, now: @escaping () -> Date = Date.init) {
        self.latency = latency
        self.now = now
        self.rng = SeededRandom(seed: seed)
    }

    public func transport(device: String) -> InMemorySyncTransport {
        let t = InMemorySyncTransport(hub: self, device: device)
        lock.withLock { transports.add(t) }
        return t
    }

    func append(_ batch: SyncBatch) {
        let delay = latency.lowerBound == latency.upperBound ? latency.lowerBound : Double.random(in: latency, using: &rng)
        lock.withLock {
            let lastVisible = logs[batch.device]?.last?.visibleAt ?? .distantPast
            logs[batch.device, default: []].append((batch, max(lastVisible, now().addingTimeInterval(delay))))
        }
        let others = lock.withLock { transports.allObjects.filter { $0.device != batch.device } }
        for t in others { t.onRemoteChange?() }
    }

    /// Every device's visible batches (including the caller's own; the
    /// engine skips those, which keeps this correct after a device id reset).
    func visible(after cursor: [String: Int]) -> [SyncBatch] {
        let t = now()
        return lock.withLock {
            logs.flatMap { dev, entries in
                entries.filter { $0.visibleAt <= t && $0.batch.seq > (cursor[dev] ?? 0) }.map(\.batch)
            }
        }
    }

    /// Batches published by a device, for assertions.
    public func batches(from device: String) -> [SyncBatch] {
        lock.withLock { logs[device]?.map(\.batch) ?? [] }
    }

    /// Drop everything a device published before `seq` (simulates compaction).
    public func replaceLog(of device: String, with batch: SyncBatch) {
        lock.withLock { logs[device] = [(batch, now())] }
    }
}

public final class InMemorySyncTransport: SyncTransport {
    let hub: InMemorySyncHub
    let device: String
    public var onRemoteChange: (() -> Void)?
    /// When set, publishing throws (to exercise the outbox / error paths).
    public var failPublishes = false
    /// Every N publishes, write a snapshot instead (exercise compaction).
    public var snapshotEvery: Int?
    private var publishCount = 0

    init(hub: InMemorySyncHub, device: String) {
        self.hub = hub
        self.device = device
    }

    public func publish(_ batch: SyncBatch, snapshot: () -> SyncBatch) throws {
        if failPublishes { throw SyncTransportError.unavailable("in-memory transport set to fail") }
        publishCount += 1
        if let every = snapshotEvery, publishCount % every == 0 {
            hub.replaceLog(of: device, with: snapshot())
        } else {
            hub.append(batch)
        }
    }

    public func fetch(after cursor: [String: Int]) throws -> [SyncBatch] {
        hub.visible(after: cursor)
    }

    public var debugDescription: String { "In-memory (\(device))" }
}

public enum SyncTransportError: Error, LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        }
    }
}

/// Seedable RNG for reproducible latency in tests (SplitMix64); falls back to
/// the system RNG when unseeded.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64?
    private var system = SystemRandomNumberGenerator()

    init(seed: UInt64?) { state = seed }

    mutating func next() -> UInt64 {
        guard var s = state else { return system.next() }
        s &+= 0x9E3779B97F4A7C15
        state = s
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
