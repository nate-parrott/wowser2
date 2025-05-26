import SwiftUI

struct WithSnapshot<S: Equatable & Codable, V: View, Snapshot: Equatable>: View {
    var store: DataStore<S>
    var snapshot: (S) -> Snapshot
    @ViewBuilder var main: (Snapshot?) -> V

    @State private var val: Snapshot? = nil


    var body: some View {
        ZStack {
            main(val)
        }
        .onReceive(store.uiPublisher.map(snapshot).removeDuplicates(), perform: { self.val = $0 })
    }
}

// Use this variant for main-thread snapshots to always get a non-async non-nil value
struct WithSnapshotMain<S: Equatable & Codable, V: View, Snapshot: Equatable>: View {
    var store: DataStore<S>
    var snapshot: (S) -> Snapshot
    @ViewBuilder var main: (Snapshot) -> V

    @State private var val: Snapshot? = nil


    var body: some View {
        ZStack {
            main(val ?? snapshot(store.model))
        }
        // If val is nil, we'll fetch the latest snapshot from the store sync.
        // Then we might receive an OLDER value from uiPublisher, so we dropFirst.
        .onReceive(store.uiPublisher.map(snapshot).removeDuplicates().dropFirst(val == nil ? 1 : 0), perform: { self.val = $0 })
    }
}
