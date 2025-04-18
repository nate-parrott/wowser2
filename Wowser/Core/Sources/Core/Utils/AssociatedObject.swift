import ObjectiveC

private class AssociatedObjectValue<T>: NSObject {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

public class AssociatedObjectKey<T> {
    public init() {
    }
    var key: UnsafeMutableRawPointer {
        return Unmanaged.passUnretained(self).toOpaque()
    }
}

extension NSObject {
    public func getAssociatedObject<T>(forKey key: AssociatedObjectKey<T>) -> T? {
        return (objc_getAssociatedObject(self, key.key) as? AssociatedObjectValue<T>)?.value
    }
    public func setAssociatedObject<T>(_ value: T?, forKey key: AssociatedObjectKey<T>) {
        if let val = value {
            objc_setAssociatedObject(self, key.key, AssociatedObjectValue<T>(val), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else {
            objc_setAssociatedObject(self, key.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
