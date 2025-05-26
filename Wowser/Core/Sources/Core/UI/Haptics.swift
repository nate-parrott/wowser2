import UIKit

class Haptics {
    static let shared = Haptics()

    init() {}

    #if os(iOS)
    private let selection = UISelectionFeedbackGenerator()
    private let notif = UINotificationFeedbackGenerator()
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let type = UIImpactFeedbackGenerator(style: .light)
    #endif

    func performSelectionHaptic() {
        #if os(iOS)
        selection.selectionChanged()
        #endif
    }

//    func performTypeHaptic() {
//        type.impactOccurred()
//    }
//
//    func performSuccessHaptic() {
//        notif.notificationOccurred(.success)
//    }
//
//    func performFailureHaptic() {
//        notif.notificationOccurred(.error)
//    }
//
//    func performWarningHaptic() {
//        notif.notificationOccurred(.warning)
//    }
//
//    func performSoftHaptic() {
//        soft.impactOccurred()
//    }
}
