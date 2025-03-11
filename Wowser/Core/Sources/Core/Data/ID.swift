import Foundation

public struct ID<Element>: Hashable, Codable, Equatable {
    public var raw: String
    
    public init(raw: String) {
        self.raw = raw
    }
    
    public static func assign() -> ID<Element> {
        .init(raw: UUID().uuidString)
    }
}
