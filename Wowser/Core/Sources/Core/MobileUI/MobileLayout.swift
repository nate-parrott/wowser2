import SwiftUI

/// Phone geometry, all in full-screen points (origin at the top-left of the
/// display, safe areas included). The page card fills the safe area; dragging
/// the puck up lifts it by `cardTravel` to reveal the tray underneath.
struct MobileLayout: Equatable {
    var size: CGSize
    var safeArea: EdgeInsets

    static let cardInset: CGFloat = 0
    static let cardCornerRadius: CGFloat = 30
    static let puckSize: CGFloat = 60
    /// Gap between the lifted card's bottom edge and the tray.
    static let trayGap: CGFloat = 14

    var cardRect: CGRect {
        CGRect(
            x: Self.cardInset,
            y: safeArea.top,
            width: size.width - Self.cardInset * 2,
            height: max(0, size.height - safeArea.top - safeArea.bottom)
        )
    }

    /// Same height in every space; content scrolls inside it.
    var trayHeight: CGFloat { (cardRect.height * 0.73).rounded() }
    var trayTop: CGFloat { cardRect.maxY - trayHeight }
    var cardTravel: CGFloat { trayHeight + Self.trayGap }

    /// Puck center at rest, and how far up it travels to fully open the tray
    /// (it then sits ~85% over the lifted card's bottom edge).
    var puckRestY: CGFloat { cardRect.maxY - 46 }
    var puckTravel: CGFloat { cardTravel - 25 }

    var puckSnapXs: [CGFloat] { [50, size.width / 2, size.width - 50] }

    /// Where the command bar card's top edge sits.
    var commandBarTop: CGFloat { safeArea.top + 96 }
}

extension MomentumValue.SpringParams {
    /// Tight and critically-ish damped: settles fast without visible bounce,
    /// carrying the release velocity.
    static let mobilePuck = MomentumValue.SpringParams(response: 0.32, dampingRatio: 0.92, epsilon: 0.05)
}

// MARK: - Backdrop

/// The colored space backdrop behind the page card: the space's image if it
/// has one, else a deep gradient in its theme hues.
struct MobileSpaceBackdrop: View {
    var theme: SpaceTheme?
    var imageInfo: SpaceImageInfo?

    var body: some View {
        if let imageInfo {
            SpaceBackgroundView(info: imageInfo)
                .overlay(Color.black.opacity(0.3))
        } else {
            let primary = theme?.hue ?? 150
            let secondary = theme?.secondaryHue ?? (primary + 22)
            LinearGradient(
                stops: [
                    .init(color: Color(hue: secondary.hueFraction, saturation: 0.42, brightness: 0.23), location: 0),
                    .init(color: Color(hue: primary.hueFraction, saturation: 0.45, brightness: 0.13), location: 0.55),
                    .init(color: Color(hue: primary.hueFraction, saturation: 0.45, brightness: 0.09), location: 1),
                ],
                startPoint: UnitPoint(x: 0.37, y: 0),
                endPoint: UnitPoint(x: 0.63, y: 1)
            )
        }
    }
}

private extension Double {
    /// Degrees (any range) → 0–1 for `Color(hue:)`.
    var hueFraction: Double {
        let d = truncatingRemainder(dividingBy: 360)
        return (d < 0 ? d + 360 : d) / 360
    }
}

// MARK: - Keyboard

/// Height of the software keyboard overlapping the bottom of the screen
/// (0 when hidden). The root ignores the keyboard safe area so the command
/// bar and tray don't jump; views that must stay above it (the chat card)
/// read this instead.
@MainActor
final class MobileKeyboardObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0

    #if os(iOS)
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            MainActor.assumeIsolated { self?.height = max(0, screen.maxY - frame.minY) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.height = 0 }
        })
    }
    #endif
}
