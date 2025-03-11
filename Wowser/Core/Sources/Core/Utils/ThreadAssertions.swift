import Foundation

public func isRunningTests() -> Bool {
#if DEBUG
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        // Code only executes when tests are running
        return true
    }
#endif
    return false

}

public func assertOnMainThread() {
#if DEBUG
    assert(Thread.isMainThread)
#endif
}

public func assertNotOnMainThread() {
    #if DEBUG
    if !isRunningTests() {
        assert(!Thread.isMainThread)
    }
    #endif
}
