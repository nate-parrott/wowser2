import Foundation

public enum Preheat {
    // Warm up caches, etc
    public static func preheat() {
        _ = ArchiveStore.shared // Force initial load on main
        OmniboxClassifierLabel.preheat()
        SafariVersion.refreshInBackground()
        #if os(macOS)
        TerminalCommandCache.shared.refreshIfNeeded()
        #endif
        Task {
            _ = await ThumbnailCache.shared
        }
        // Sync: once windows exist (it reads the primary window's tabs).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SyncController.shared.startIfEnabled()
        }
        // Memory store: late, and a no-op unless the user turned it on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            MemoryStore.shared.startLate()
        }
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//            DispatchQueue.global().async {
//                OmniboxClassifierLabel.preheat()
//            }
//        }
    }
}
