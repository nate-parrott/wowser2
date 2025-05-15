import SwiftUI

struct ToastFirstTimeCleanModeAutoActivates: ViewModifier {
    var paneID: ID<WebContent>?
    @Environment(\.windowID) private var windowID
    
    func body(content: Content) -> some View {
        content
            .background {
                if let paneID {
                    Color.clear
                        .onReceive(CleanModeStore.shared.cleanModeSnapshotForPane(id: paneID).removeDuplicates().map { $0.hostIfAutoActivated }.removeDuplicates()) { host in
                            if let host {
                                // we're active on this host
                                let defaultsKey = "CleanMode.Toasted:\(host)"
                                if !UserDefaults.standard.bool(forKey: defaultsKey), let windowID {
                                    UserDefaults.standard.set(true, forKey: defaultsKey)
                                    BrowserStore.shared.model.addToast(message: "Clean Mode activated", icon: "lasso.badge.sparkles", in: windowID)
                                }
                            }
                        }
                }
            }
    }
}

private extension CleanModeSnapshotForPane {
    var hostIfAutoActivated: String? {
        cssAvail || wantsReader ? hostWithoutWWW : nil
    }
}
