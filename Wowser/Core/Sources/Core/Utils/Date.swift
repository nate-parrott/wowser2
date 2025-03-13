import Foundation

extension Date {
    func isWithinPast(hours: TimeInterval) -> Bool {
        self > Date(timeIntervalSinceNow: -hours * 60 * 60)
    }
    
    func isWithinPast(minutes: TimeInterval) -> Bool {
        self > Date(timeIntervalSinceNow: -minutes * 60)
    }
}
