import Foundation

public struct IdentifiedArray<T: Identifiable & Equatable & Codable>: Equatable, Codable where T.ID: Codable {
    private var order = [T.ID]()
    private var byId = [T.ID: T]()
    
    public init(items: [T] = []) {
        order = items.map(\.id)
        for item in items {
            byId[item.id] = item
        }
    }
    
    // MARK: - Collection Conformance
    
    /// Returns count of items in the array
    public var count: Int {
        return order.count
    }
    
    /// Returns a Boolean value indicating whether the collection is empty
    public var isEmpty: Bool {
        return order.isEmpty
    }
    
    /// Returns all elements as an array
    public var elements: [T] {
        return order.compactMap { byId[$0] }
    }
    
    // MARK: - Subscripts
    
    /// Subscript for accessing and modifying elements by index
    public subscript(index: Int) -> T? {
        get {
            guard index >= 0, index < order.count else { return nil }
            let id = order[index]
            return byId[id]
        }
        set {
            guard index >= 0, index < order.count, let newValue = newValue else { return }
            let oldId = order[index]
            byId[oldId] = nil
            order[index] = newValue.id
            byId[newValue.id] = newValue
        }
    }
    
    /// Subscript for accessing and modifying elements by ID
    public subscript(id: T.ID) -> T? {
        get {
            return byId[id]
        }
        set {
            if let newValue = newValue {
                // If the ID is already in the order array, update the value
                if byId[id] != nil {
                    byId[id] = newValue
                } else {
                    // If the ID doesn't exist in the order array, append it
                    order.append(newValue.id)
                    byId[newValue.id] = newValue
                }
            } else {
                // If the new value is nil, remove the element
                if let index = order.firstIndex(of: id) {
                    order.remove(at: index)
                }
                byId[id] = nil
            }
        }
    }
    
    // MARK: - Mutation Methods
    
    /// Append an item to the end of the array
    public mutating func append(_ item: T) {
        // If item with this ID already exists, remove it first
        if byId[item.id] != nil {
            remove(id: item.id)
        }
        
        order.append(item.id)
        byId[item.id] = item
    }
    
    /// Insert an item at the specified index
    public mutating func insert(_ item: T, at index: Int) {
        // If item with this ID already exists, remove it first
        if byId[item.id] != nil {
            remove(id: item.id)
        }
        
        // Ensure index is within bounds for insertion
        let safeIndex = Swift.min(Swift.max(0, index), order.count)
        
        order.insert(item.id, at: safeIndex)
        byId[item.id] = item
    }
    
    /// Remove an item by its ID
    @discardableResult
    public mutating func remove(id: T.ID) -> T? {
        guard let index = order.firstIndex(of: id) else { return nil }
        order.remove(at: index)
        return byId.removeValue(forKey: id)
    }
    
    /// Remove an item at the specified index
    @discardableResult
    public mutating func remove(at index: Int) -> T? {
        guard index >= 0, index < order.count else { return nil }
        let id = order[index]
        order.remove(at: index)
        return byId.removeValue(forKey: id)
    }
    
    public var first: T? {
        if let id = order.first {
            return byId[id]!
        }
        return nil
    }
}

// MARK: - Sequence Conformance
extension IdentifiedArray: Sequence {
    public struct Iterator: IteratorProtocol {
        private var index = 0
        private let array: IdentifiedArray<T>
        
        init(array: IdentifiedArray<T>) {
            self.array = array
        }
        
        public mutating func next() -> T? {
            guard index < array.order.count else { return nil }
            defer { index += 1 }
            return array[index]
        }
    }
    
    public func makeIterator() -> Iterator {
        return Iterator(array: self)
    }
}
