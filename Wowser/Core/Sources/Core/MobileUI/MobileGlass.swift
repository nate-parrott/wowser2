import SwiftUI

/// Liquid glass that stays dark. SwiftUI's `glassEffect` flips between light
/// and dark with the luminance of whatever is behind it, and offers no switch;
/// a UIKit glass view with a pinned interface style doesn't.
enum MobileGlassShape: Equatable {
    case capsule
    case rounded(CGFloat)
}

extension View {
    /// Dark liquid glass behind this view, in `shape`, optionally tinted.
    /// `enabled: false` draws nothing (like `Glass.identity`).
    func mobileGlass(_ shape: MobileGlassShape, tint: Color? = nil, enabled: Bool = true) -> some View {
        background {
            if enabled {
                MobileGlassView(shape: shape, tint: tint)
                    .allowsHitTesting(false)
            }
        }
    }
}

#if os(iOS)
private struct MobileGlassView: UIViewRepresentable {
    var shape: MobileGlassShape
    var tint: Color?

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView()
        view.overrideUserInterfaceStyle = .dark
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// What's been applied, so re-renders that change nothing don't touch
    /// the effect (rebuilding glass is expensive).
    final class Coordinator {
        var shape: MobileGlassShape?
        var tint: Color??
    }

    private func apply(to view: UIVisualEffectView, coordinator: Coordinator) {
        if coordinator.tint != .some(tint) {
            coordinator.tint = .some(tint)
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint.map(UIColor.init)
            view.effect = effect
        }
        if coordinator.shape != shape {
            coordinator.shape = shape
            switch shape {
            case .capsule: view.cornerConfiguration = .capsule()
            case .rounded(let radius): view.cornerConfiguration = .corners(radius: .fixed(radius))
            }
        }
    }
}
#else
private struct MobileGlassView: View {
    var shape: MobileGlassShape
    var tint: Color?

    var body: some View {
        switch shape {
        case .capsule:
            Color.clear.glassEffect(.regular.tint(tint), in: Capsule())
        case .rounded(let radius):
            Color.clear.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
#endif
