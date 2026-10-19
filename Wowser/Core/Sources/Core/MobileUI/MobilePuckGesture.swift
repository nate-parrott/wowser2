import SwiftUI

/// What the puck's touch reports, in window points.
enum MobilePuckTouch {
    case down
    case moved(translation: CGSize)
    case up(translation: CGSize, velocity: CGSize)
    case cancelled
}

extension View {
    func mobilePuckGesture(_ handler: @escaping (MobilePuckTouch) -> Void) -> some View {
        #if os(iOS)
        gesture(MobilePuckGesture(handler: handler))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// The puck's drag, as a UIKit recognizer rather than a SwiftUI DragGesture:
/// UIKit delivers one coalesced update per display frame, and a zero-
/// duration long press fires on touch-down (for the pressed look) and then
/// tracks movement like a pan.
private struct MobilePuckGesture: UIGestureRecognizerRepresentable {
    var handler: (MobilePuckTouch) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.handle(press, handler: handler)
    }

    @MainActor
    final class Coordinator {
        private var start: CGPoint = .zero
        /// Recent (time, location) samples for the release velocity.
        private var samples: [(t: TimeInterval, p: CGPoint)] = []

        func handle(_ press: UILongPressGestureRecognizer, handler: (MobilePuckTouch) -> Void) {
            let p = press.location(in: nil)
            let now = CACurrentMediaTime()
            switch press.state {
            case .began:
                start = p
                samples = [(now, p)]
                handler(.down)
            case .changed:
                record(now, p)
                handler(.moved(translation: CGSize(width: p.x - start.x, height: p.y - start.y)))
            case .ended:
                record(now, p)
                handler(.up(translation: CGSize(width: p.x - start.x, height: p.y - start.y), velocity: velocity(at: now)))
            case .cancelled, .failed:
                handler(.cancelled)
            default:
                break
            }
        }

        private func record(_ t: TimeInterval, _ p: CGPoint) {
            samples.append((t, p))
            samples.removeAll { t - $0.t > 0.1 }
        }

        /// Points per second over the last ~100ms (zero if the finger rested).
        private func velocity(at now: TimeInterval) -> CGSize {
            guard let first = samples.first, let last = samples.last, last.t - first.t > 0.008 else { return .zero }
            let dt = last.t - first.t
            return CGSize(width: (last.p.x - first.p.x) / dt, height: (last.p.y - first.p.y) / dt)
        }
    }
}
#endif
