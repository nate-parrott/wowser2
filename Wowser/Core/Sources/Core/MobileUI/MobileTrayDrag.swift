import SwiftUI

extension View {
    /// Dragging on this view steers the tray like dragging the puck: the
    /// finger moves `lift` directly, and release springs it open or shut with
    /// the gesture's velocity.
    func mobileTrayDrag(lift: MomentumValue, travel: CGFloat) -> some View {
        #if os(iOS)
        gesture(MobileTrayDragGesture(lift: lift, travel: travel))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// A pan that runs alongside the tray's own scroll views and takes over from
/// them at the top edge, in one continuous gesture: a tab list scrolled down
/// keeps scrolling until it reaches its top, then further pulling closes the
/// tray; reversing past fully open hands the finger back to the list.
///
/// SwiftUI can't express this (nested same-axis scroll views don't hand off
/// on iOS, and a page-wide outer ScrollView would also fight the web view's
/// scrolling), so this gets the list's UIScrollView from the simultaneous-
/// recognition callback and pins it while the tray moves.
private struct MobileTrayDragGesture: UIGestureRecognizerRepresentable {
    var lift: MomentumValue
    var travel: CGFloat

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(pan, lift: lift, travel: travel)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The vertical list under the finger, if any.
        private weak var list: UIScrollView?
        private var lastY: CGFloat = 0
        private var steering = false
        private var listBounced = true

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            // Sideways swipes belong to the space pager.
            return abs(v.y) > abs(v.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if let scrollView = other.view as? UIScrollView, other === scrollView.panGestureRecognizer,
               scrollView.contentSize.width <= scrollView.bounds.width + 1 {
                list = scrollView
            }
            return true
        }

        func handle(_ pan: UIPanGestureRecognizer, lift: MomentumValue, travel: CGFloat) {
            let y = pan.translation(in: nil).y
            switch pan.state {
            case .began:
                lastY = y
                steering = false
            case .changed:
                let delta = y - lastY
                lastY = y
                if !steering {
                    // Nothing scrollable under the finger: always steer.
                    // Over a list: only once it's at the top and pulled down.
                    if let list {
                        guard delta > 0, isAtTop(list) else { return }
                    }
                    startSteering()
                }
                lift.value -= Double(delta)
                if let list {
                    pinToTop(list)
                    if lift.value >= Double(travel), delta < 0 {
                        // Back at fully open: the list scrolls again.
                        lift.value = Double(travel)
                        stopSteering()
                    }
                }
            case .ended, .cancelled, .failed:
                if steering {
                    let v = pan.state == .ended ? pan.velocity(in: nil).y : 0
                    if lift.rubberBandedValue != lift.value { lift.value = lift.rubberBandedValue }
                    let projected = CGFloat(lift.value) - v * 0.15
                    lift.animate(toValue: projected > travel / 2 ? travel : 0, velocity: -v)
                    stopSteering()
                }
                list = nil
            default:
                break
            }
        }

        private func startSteering() {
            steering = true
            if let list {
                listBounced = list.bounces
                list.bounces = false
                pinToTop(list)
            }
        }

        private func stopSteering() {
            steering = false
            guard let list else { return }
            let bounced = listBounced
            // After the list's own pan has ended and started decelerating:
            // stop that, then restore bouncing.
            DispatchQueue.main.async {
                self.pinToTop(list)
                list.bounces = bounced
            }
        }

        private func isAtTop(_ list: UIScrollView) -> Bool {
            list.contentOffset.y <= -list.adjustedContentInset.top + 0.5
        }

        private func pinToTop(_ list: UIScrollView) {
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: -list.adjustedContentInset.top), animated: false)
        }
    }
}
#endif
