import Foundation

public enum Preheat {
    // Warm up caches, etc
    public static func preheat() {
        _ = ArchiveStore.shared // Force initial load on main
        OmniboxClassifierLabel.preheat()
        DictationController.shared.setup()
        Task {
            _ = await ThumbnailCache.shared
        }
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//            DispatchQueue.global().async {
//                OmniboxClassifierLabel.preheat()
//            }
//        }
    }
}
