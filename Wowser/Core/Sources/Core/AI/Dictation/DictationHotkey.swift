import Foundation
#if os(macOS)
import AppKit
#endif

/// Push-to-talk shortcut for dictation, chosen in Settings → Dictation.
/// Every option is hold-to-talk: dictation starts while held and commits on
/// release. (⌘D stays a tap-to-toggle menu shortcut regardless.)
public enum DictationHotkey: String, CaseIterable, Identifiable {
    /// Hold ⌘⌥ alone for a second.
    case commandOption
    /// Hold ⌘K.
    case commandK
    /// Hold ⌘⌥/.
    case commandOptionSlash
    case off

    public static let `default` = DictationHotkey.commandOption

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .commandOption: return "Hold ⌘⌥"
        case .commandK: return "Hold ⌘K"
        case .commandOptionSlash: return "Hold ⌘⌥/"
        case .off: return "Off"
        }
    }

    public static var current: DictationHotkey {
        DictationHotkey(rawValue: DefaultsKeys.dictationHotkey.stringValue()) ?? .default
    }
}

#if os(macOS)
private extension DictationHotkey {
    /// Modifiers that must be held, exactly.
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .commandOption, .commandOptionSlash: return [.command, .option]
        case .commandK: return [.command]
        case .off: return []
        }
    }

    /// The non-modifier key of a chord (`charactersIgnoringModifiers`), or nil
    /// for the modifier-only hold.
    var key: String? {
        switch self {
        case .commandK: return "k"
        case .commandOptionSlash: return "/"
        case .commandOption, .off: return nil
        }
    }
}

/// Watches key events app-wide (local monitors, so only while we're active)
/// and drives `DictationController` for the configured push-to-talk hotkey.
@MainActor
public final class DictationHotkeyMonitor {
    public static let shared = DictationHotkeyMonitor()

    /// How long ⌘⌥ must be held, with nothing else pressed, to start.
    static let modifierHoldDelay: TimeInterval = 1

    /// Supplied by the app: the key window's focused pane and window.
    public var resolveContext: (() -> (paneID: ID<WebContent>?, windowID: ID<WindowState>)?)?

    private var monitors: [Any] = []
    private var holdTimer: Timer?
    /// A session this monitor started; releasing the hotkey commits it.
    private var holding = false

    private init() {}

    public func install() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }) {
            monitors.append(m)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let hotkey = DictationHotkey.current
        guard hotkey != .off else {
            cancelHoldTimer()
            return event
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.type {
        case .flagsChanged:
            if holding {
                // Releasing (or changing) the modifiers ends the session.
                if mods != hotkey.modifiers { release() }
            } else if hotkey.key == nil {
                if mods == hotkey.modifiers {
                    armHoldTimer()
                } else {
                    cancelHoldTimer()
                }
            }
            return event

        case .keyDown:
            // Any key during the ⌘⌥ hold means it's a shortcut, not dictation.
            cancelHoldTimer()
            guard let key = hotkey.key, mods == hotkey.modifiers,
                  event.charactersIgnoringModifiers?.lowercased() == key else { return event }
            if !holding, !event.isARepeat {
                press()
            }
            return nil // swallow the chord (and its auto-repeats)

        case .keyUp:
            if holding, let key = hotkey.key, event.charactersIgnoringModifiers?.lowercased() == key {
                release()
                return nil
            }
            return event

        default: // mouse down: ⌘⌥-click etc. isn't a dictation hold
            cancelHoldTimer()
            return event
        }
    }

    private func armHoldTimer() {
        guard holdTimer == nil, !DictationController.shared.isActive else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.modifierHoldDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.holdTimer = nil
                self?.press()
            }
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func press() {
        let controller = DictationController.shared
        guard !controller.isActive, let context = resolveContext?() else { return }
        holding = true
        controller.start(target: controller.resolveTarget(paneID: context.paneID, windowID: context.windowID))
    }

    private func release() {
        guard holding else { return }
        holding = false
        let controller = DictationController.shared
        switch controller.phase {
        case .listening: controller.commit()
        case .starting: controller.cancel() // let go before the mic came up
        case .idle, .committing: break
        }
    }
}
#endif
