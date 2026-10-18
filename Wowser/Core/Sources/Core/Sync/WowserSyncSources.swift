import Foundation
import Combine

/// The latest value of a DataStore, readable from any thread without a
/// synchronous hop to the store's queue. The sync engine projects from this
/// on its own queue (a value-type copy, so it's cheap and consistent).
final class StoreSnapshot<Model: Equatable & Codable> {
    private let lock = NSLock()
    private var value: Model?
    private var sub: AnyCancellable?
    let changes = PassthroughSubject<Void, Never>()

    init(_ store: DataStore<Model>) {
        sub = store.publisher.sink { [weak self] model in
            guard let self else { return }
            self.lock.withLock { self.value = model }
            self.changes.send()
        }
    }

    var latest: Model? { lock.withLock { value } }
}

// MARK: - Spaces, tabs, panes

final class BrowserSyncSource: SyncSource {
    let id = "browser"
    let store: BrowserStore
    let snapshot: StoreSnapshot<BrowserState>
    private var subs = Set<AnyCancellable>()
    private var lastCurrentTabs = Set<ID<Tab>>()

    /// Read by the change hook that pins the primary window.
    static var isActive = false
    private static var installedHooks = false

    var collections: [SyncCollectionSpec] { BrowserSyncSchema.collections }
    var localChanges: AnyPublisher<Void, Never> { snapshot.changes.eraseToAnyPublisher() }

    init(store: BrowserStore, snapshot: StoreSnapshot<BrowserState>) {
        self.store = store
        self.snapshot = snapshot
        Self.installHooks(store)
        // "Reopen" = a tab becomes some window's current tab: load what other
        // devices navigated it to while it was open here.
        store.publisher
            .map { Set($0.windows.values.compactMap(\.currentTab)) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in self?.currentTabsChanged(current) }
            .store(in: &subs)
    }

    private static func installHooks(_ store: BrowserStore) {
        guard !installedHooks else { return }
        installedHooks = true
        store.addChangeHook { _, next in
            guard BrowserSyncSource.isActive else { return }
            let pinned = next.sync?.primaryWindowID
            if pinned.flatMap({ next.windows[$0] }) == nil, let w = next.activeWindow, w.id != pinned {
                if next.sync == nil { next.sync = BrowserSyncLocalState() }
                next.sync?.primaryWindowID = w.id
            }
        }
    }

    private func currentTabsChanged(_ current: Set<ID<Tab>>) {
        let opened = current.subtracting(lastCurrentTabs)
        lastCurrentTabs = current
        for tabID in opened where store.model.tabs[tabID]?.panes.contains(where: { $0.syncPendingNav != nil }) == true {
            var loads = [(pane: ID<WebContent>, url: URL)]()
            store.modify { loads = $0.adoptSyncPendingNavigations(tabID: tabID) }
            for load in loads {
                store.existingWebContent(forId: load.pane)?.load(url: load.url)
            }
        }
    }

    func project() -> SyncProjection? {
        snapshot.latest?.syncProjection()
    }

    /// Background changes in flight (image ingest is async), so a retry
    /// round doesn't start the same one twice.
    private var pendingEffects = [BrowserSyncEffect: Date]()

    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        DispatchQueue.main.async { [store] in
            let live = Set(store.liveWebContentIDs)
            var effects = [BrowserSyncEffect]()
            store.modify { effects = $0.applySync(update, livePanes: live) }
            let now = Date()
            self.pendingEffects = self.pendingEffects.filter { now.timeIntervalSince($0.value) < 30 }
            effects = effects.filter { self.pendingEffects[$0] == nil }
            for effect in effects {
                self.pendingEffects[effect] = now
                switch effect {
                case let .setBuiltinBackground(profile, builtinID, mode):
                    guard let bg = BuiltinSpaceBackground.all.first(where: { $0.id == builtinID }) else { continue }
                    store.setBuiltinSpaceBackground(bg, profileID: profile, mode: mode ?? .fade)
                case let .clearBackground(profile):
                    store.clearSpaceBackgroundImage(profileID: profile)
                }
            }
            completion()
        }
    }
}

// MARK: - History

final class HistorySyncSource: SyncSource {
    let id = "history"
    let browser: StoreSnapshot<BrowserState>

    var collections: [SyncCollectionSpec] { HistorySyncSchema.collections }
    var localChanges: AnyPublisher<Void, Never> { HistoryStore.didChange.eraseToAnyPublisher() }

    init(browser: StoreSnapshot<BrowserState>) {
        self.browser = browser
    }

    /// Login group → local data store, one per group.
    private func groups() -> [String: UUID]? {
        guard let state = browser.latest else { return nil }
        var out = [String: UUID]()
        for p in state.profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }) {
            let g = state.syncLoginGroup(forDataStore: p.dataStoreUUID)
            if out[g] == nil { out[g] = p.dataStoreUUID }
        }
        return out
    }

    func project() -> SyncProjection? {
        guard let groups = groups() else { return nil }
        var p = SyncProjection()
        p.declare(HistorySyncSchema.collection)
        Queue.historyQueue.runSync {
            for (group, uuid) in groups {
                let records = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(uuid).model.syncRecords(group: group)
                p.records[HistorySyncSchema.collection]!.merge(records) { a, _ in a }
            }
        }
        return p
    }

    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        let groups = groups() ?? [:]
        Queue.historyQueue.run {
            let col = HistorySyncSchema.collection
            for key in update.changedKeys(col) {
                guard let (group, historyKey) = HistorySyncSchema.parse(key), let uuid = groups[group],
                      let all = update.doc.fields(col, key) else { continue }
                let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(uuid)
                let current = store.model.items[historyKey]?.syncFields
                guard let fields = update.fieldsToApply(col, key, current: current), !fields.isEmpty else { continue }
                store.modify { $0.applySync(historyKey: historyKey, fields: fields, all: all) }
            }
            completion()
        }
    }
}

// MARK: - Autofill (everything but saved logins)

final class AutofillSyncSource: SyncSource {
    let id = "autofill"
    let store: AutofillStore
    let snapshot: StoreSnapshot<AutofillState>

    var collections: [SyncCollectionSpec] { AutofillSyncSchema.collections }
    var localChanges: AnyPublisher<Void, Never> { snapshot.changes.eraseToAnyPublisher() }

    init(store: AutofillStore) {
        self.store = store
        self.snapshot = StoreSnapshot(store)
    }

    func project() -> SyncProjection? {
        snapshot.latest?.syncProjection()
    }

    func apply(_ update: SyncUpdate, completion: @escaping () -> Void) {
        DispatchQueue.main.async { [store] in
            store.modify { $0.applySync(update) }
            completion()
        }
    }
}
