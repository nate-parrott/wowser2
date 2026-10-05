import Foundation
import os
#if os(macOS)
import AppKit
import ObjectiveC
#endif

/// Opt-in per-second counters for diagnosing render / layout / cursor churn
/// (e.g. the fullscreen choppiness on native pages). Off by default; costs one
/// bool check per call site when off.
///
/// Enable:  `defaults write com.nateparrott.tangerine renderStatsLogging -bool YES` (relaunch)
/// Read:    `log stream --predicate 'subsystem == "com.nateparrott.tangerine" AND category == "RenderStats"'`
///
/// Each second with activity logs one line of counters, plus one-off `note`s
/// (e.g. hosting-view frame or safe-area changes) as they happen.
public enum RenderStats {
    public static let enabled = DefaultsKeys.renderStatsLogging.boolValue()

    private static let logger = Logger(subsystem: "com.nateparrott.tangerine", category: "RenderStats")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var started = false

    @inline(__always)
    public static func hit(_ name: StaticString) {
        guard enabled else { return }
        lock.lock()
        counts["\(name)", default: 0] += 1
        lock.unlock()
    }

    public static func note(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let m = message()
        logger.log("note: \(m, privacy: .public)")
    }

    /// Call once at launch (main thread). No-op unless enabled.
    public static func start() {
        guard enabled, !started else { return }
        started = true
        #if os(macOS)
        countCursorSets()
        #endif
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            hit("runloop.wake")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in flush() }
        RunLoop.main.add(timer, forMode: .common)
        logger.log("RenderStats on")
    }

    private static func flush() {
        lock.lock()
        let snapshot = counts
        counts.removeAll(keepingCapacity: true)
        lock.unlock()
        // The flush timer itself wakes the run loop once a second.
        guard snapshot.contains(where: { $0.key != "runloop.wake" }) else { return }
        #if os(macOS)
        let fullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
        #else
        let fullscreen = false
        #endif
        let line = snapshot.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.log("\(fullscreen ? "[FS] " : "", privacy: .public)\(line, privacy: .public)")
    }

    #if os(macOS)
    /// Counts `NSCursor.set` calls: a cursor reset on every mouse move is a
    /// classic source of cursor stutter.
    private static func countCursorSets() {
        let selector = #selector(NSCursor.set)
        guard let method = class_getInstanceMethod(NSCursor.self, selector) else { return }
        typealias SetFn = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SetFn.self)
        let replacement: @convention(block) (AnyObject) -> Void = { cursor in
            hit("NSCursor.set")
            original(cursor, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
    #endif
}
