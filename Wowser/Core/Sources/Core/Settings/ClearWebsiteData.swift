import SwiftUI
import WebKit

extension BrowserStore {
    /// Removes all website data (cookies, caches, local storage, IndexedDB,
    /// service workers…) from one website data store — i.e. for every space
    /// sharing those logins. History, favorites, tabs and autofill/passwords
    /// are untouched. Open pages keep running; they'll be logged out on reload.
    @MainActor
    public func clearWebsiteData(dataStoreUUID: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreUUID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Settings › Profiles: "Clear cookies and site data" for one login group
/// (one website data store).
struct ClearWebsiteDataRow: View {
    var dataStoreUUID: UUID
    var spaceNames: [String]

    @State private var confirming = false
    @State private var clearing = false
    @State private var cleared = false

    var body: some View {
        LabeledContent {
            HStack {
                if clearing {
                    ProgressView().controlSize(.small)
                }
                Button(cleared ? "Cleared" : "Clear…") { confirming = true }
                    .disabled(clearing || cleared)
            }
        } label: {
            Text("Cookies and site data")
            Text("Logs you out of every site in \(spaceList). History and passwords are kept.")
        }
        .confirmationDialog("Clear cookies and site data for \(spaceList)?", isPresented: $confirming) {
            Button("Clear", role: .destructive, action: clear)
        } message: {
            Text("You'll be logged out of every site in these spaces. History, favorites and saved passwords are kept.")
        }
    }

    private var spaceList: String {
        ListFormatter.localizedString(byJoining: spaceNames)
    }

    private func clear() {
        clearing = true
        Task {
            await BrowserStore.shared.clearWebsiteData(dataStoreUUID: dataStoreUUID)
            clearing = false
            cleared = true
        }
    }
}
