import Foundation

struct DecayedCounter: Equatable, Codable {
    var lastCount: Double = 0
    var lastUpdateDate: Date?
    
    mutating func add(count: Double, interval: TimeInterval) {
        lastCount = decayedCount(interval: interval) + count
        lastUpdateDate = Date()
    }
    
    func decayedCount(interval: TimeInterval) -> Double {
        if let lastUpdateDate {
            let halfLives = max(0, (Date.now.timeIntervalSinceReferenceDate - lastUpdateDate.timeIntervalSinceReferenceDate) / interval)
            return lastCount / pow(2, halfLives)
        }
        return 0
    }
}
