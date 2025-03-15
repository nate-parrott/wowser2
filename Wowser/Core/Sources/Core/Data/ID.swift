import Foundation

public struct ID<Element>: Hashable, Codable, Equatable, Identifiable {
    public var raw: String
    
    public init(raw: String) {
        self.raw = raw
    }
    
    public static func assign() -> Core.ID<Element> {
        .init(raw: UUID().uuidString)
    }
    
    public var id: String {
        raw
    }
}
