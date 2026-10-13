import SwiftUI

/// Looping "working" animations for `WowieAvatar`. All are periodic, and switching
/// between them cross-fades the poses so the avatar never jumps.
public enum WowieAnimation: String, CaseIterable, Identifiable, Sendable {
    /// Mouth chatters, antenna jitters.
    case typing
    /// Antenna sways slowly, mouth drifts side to side.
    case thinking
    /// Hops with squash & stretch; antenna lags behind.
    case bouncing
    /// Mouth and antenna sweep back and forth together.
    case scanning
    /// Stroke weight swells and relaxes.
    case breathing

    public var id: String { rawValue }

    func pose(at t: Double) -> WowiePose {
        let tau = 2 * Double.pi
        var p = WowiePose()
        switch self {
        case .typing:
            p.mouthScale.height = 1 + 0.2 * sin(tau * 1 * t)
            p.mouthOffset.width = 0.007 * sin(tau * 0.5 * t)
            p.antennaAngle = 0.06 * sin(tau * 1.6 * t)
            p.bodyOffset.height = 0.005 * sin(tau * 1 * t)
            p.eyeOffset.height = 0.02
            p.eyeOpen = blink(t, period: 3.1)
        case .thinking:
            p.antennaAngle = 0.25 * sin(tau * 0.5 * t)
            p.mouthOffset.width = 0.06 * sin(tau * 0.25 * t)
            p.mouthRotation = 0.12 * sin(tau * 0.25 * t + 0.6)
            p.eyeOffset = CGSize(width: 0.025 * sin(tau * 0.25 * t + 1), height: -0.03)
            p.eyeOpen = blink(t, period: 4.3)
        case .bouncing:
            let phase = t * 1.2
            let hop = abs(sin(Double.pi * phase))
            let squash = cos(tau * phase)
            p.bodyOffset.height = -0.06 * hop
            p.headScale = CGSize(width: 1 + 0.04 * squash, height: 1 - 0.04 * squash)
            p.antennaAngle = 0.18 * sin(tau * phase - 1.2)
            p.eyeOffset.height = 0.012 * sin(tau * phase - 0.6)
        case .scanning:
            let s = sin(tau * 0.6 * t)
            p.mouthOffset.width = 0.1 * s
            p.mouthRotation = -0.08 * s
            p.antennaAngle = 0.35 * sin(tau * 0.6 * t + 0.5)
            p.eyeOffset.width = 0.04 * s
        case .breathing:
            let s = sin(tau * 0.4 * t)
            p.weightDelta = 0.25 * s
            p.headScale = CGSize(width: 1 + 0.02 * s, height: 1 + 0.02 * s)
            p.antennaAngle = 0.05 * sin(tau * 0.4 * t - 0.8)
            p.eyeOpen = blink(t, period: 5)
        }
        return p
    }

    /// 1 when open; dips toward closed for ~0.15s once per `period`.
    private func blink(_ t: Double, period: Double) -> CGFloat {
        let x = t.truncatingRemainder(dividingBy: period) / 0.15
        return x < 1 ? 1 - 0.9 * CGFloat(sin(Double.pi * x)) : 1
    }
}

/// Per-part offsets from the rest pose, in unit-square coordinates.
struct WowiePose {
    var mouthOffset: CGSize = .zero
    var mouthScale = CGSize(width: 1, height: 1)
    var mouthRotation: Double = 0
    var antennaAngle: Double = 0
    var headScale = CGSize(width: 1, height: 1)
    var bodyOffset: CGSize = .zero
    var weightDelta: CGFloat = 0
    var eyeOffset: CGSize = .zero
    /// Vertical eye scale: 1 open, ~0 closed.
    var eyeOpen: CGFloat = 1

    func lerp(to o: WowiePose, _ f: CGFloat) -> WowiePose {
        func l(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
        func l(_ a: CGSize, _ b: CGSize) -> CGSize { CGSize(width: l(a.width, b.width), height: l(a.height, b.height)) }
        return WowiePose(
            mouthOffset: l(mouthOffset, o.mouthOffset),
            mouthScale: l(mouthScale, o.mouthScale),
            mouthRotation: l(mouthRotation, o.mouthRotation),
            antennaAngle: l(antennaAngle, o.antennaAngle),
            headScale: l(headScale, o.headScale),
            bodyOffset: l(bodyOffset, o.bodyOffset),
            weightDelta: l(weightDelta, o.weightDelta),
            eyeOffset: l(eyeOffset, o.eyeOffset),
            eyeOpen: l(eyeOpen, o.eyeOpen)
        )
    }
}

/// The Wowie symbol drawn from its own paths, so parts can move independently.
/// `weight` runs 0 (ultralight) … 0.5 (regular) … 1 (black) and can be any value in
/// between. Changing `animation` or `weight` transitions smoothly. Fills with the
/// current foreground style.
public struct WowieAvatar: View {
    public var animation: WowieAnimation?
    public var weight: CGFloat

    public init(animation: WowieAnimation? = nil, weight: CGFloat = 0.5) {
        self.animation = animation
        self.weight = weight
    }

    private static let transition: Double = 0.5

    /// Animations currently contributing to the pose; later entries fade in over earlier ones.
    @State private var layers: [(animation: WowieAnimation?, start: Date)] = []
    @State private var weightFrom: CGFloat?
    @State private var weightChange = Date.distantPast
    @State private var settled = true

    public var body: some View {
        TimelineView(.animation(paused: animation == nil && settled)) { timeline in
            Canvas { ctx, size in
                let now = timeline.date
                let pose = currentPose(at: now)
                let w = min(max(displayedWeight(at: now) + pose.weightDelta, 0), 1)
                for path in WowieAvatar.paths(weight: w, pose: pose, size: size) {
                    ctx.fill(path, with: .foreground)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { if layers.isEmpty { layers = [(animation, .distantPast)] } }
        .onChange(of: animation) { _, new in
            let now = Date()
            // Drop layers already fully covered by a finished fade.
            if let lastDone = layers.lastIndex(where: { now.timeIntervalSince($0.start) >= Self.transition }) {
                layers.removeFirst(lastDone)
            }
            layers.append((new, now))
            settled = false
        }
        .onChange(of: weight) { old, _ in
            let now = Date()
            weightFrom = displayedWeight(at: now, target: old)
            weightChange = now
            settled = false
        }
        .task(id: settled) {
            guard !settled else { return }
            try? await Task.sleep(for: .seconds(Self.transition + 0.05))
            settled = true
        }
    }

    private static func ease(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }

    private func currentPose(at date: Date) -> WowiePose {
        let t = date.timeIntervalSinceReferenceDate
        let base = layers.isEmpty ? [(animation, Date.distantPast)] : layers
        var pose = base[0].0?.pose(at: t) ?? WowiePose()
        for layer in base.dropFirst() {
            let f = Self.ease(date.timeIntervalSince(layer.1) / Self.transition)
            pose = pose.lerp(to: layer.0?.pose(at: t) ?? WowiePose(), f)
        }
        return pose
    }

    private func displayedWeight(at date: Date, target: CGFloat? = nil) -> CGFloat {
        let target = target ?? weight
        guard let from = weightFrom else { return target }
        let f = Self.ease(date.timeIntervalSince(weightChange) / Self.transition)
        return from + (target - from) * f
    }

    // MARK: - Geometry

    // Rest-pose anchors in unit space (measured from the regular weight).
    private static let headCenter = CGPoint(x: 0.47, y: 0.54)
    private static let mouthCenter = CGPoint(x: 0.475, y: 0.705)
    private static let antennaPivot = CGPoint(x: 0.46, y: 0.215)
    private static let rightEyeCenter = CGPoint(x: 0.62, y: 0.425)
    private static let leftEyeCenter = CGPoint(x: 0.332, y: 0.46)

    private static func around(_ c: CGPoint, _ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(t).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    }

    static func paths(weight: CGFloat, pose: WowiePose, size: CGSize) -> [Path] {
        let geo = interpolatedGeometry(weight: weight)
        let side = min(size.width, size.height)
        let toView = CGAffineTransform(scaleX: side, y: side)
            .concatenating(CGAffineTransform(translationX: (size.width - side) / 2, y: (size.height - side) / 2))
        let head = around(headCenter, CGAffineTransform(scaleX: pose.headScale.width, y: pose.headScale.height))
            .concatenating(CGAffineTransform(translationX: pose.bodyOffset.width, y: pose.bodyOffset.height))
        let mouth = around(mouthCenter, CGAffineTransform(scaleX: pose.mouthScale.width, y: pose.mouthScale.height)
            .concatenating(CGAffineTransform(rotationAngle: pose.mouthRotation)))
            .concatenating(CGAffineTransform(translationX: pose.mouthOffset.width, y: pose.mouthOffset.height))
        let antenna = around(antennaPivot, CGAffineTransform(rotationAngle: pose.antennaAngle))
        func eye(_ c: CGPoint) -> CGAffineTransform {
            around(c, CGAffineTransform(scaleX: 1, y: pose.eyeOpen))
                .concatenating(CGAffineTransform(translationX: pose.eyeOffset.width, y: pose.eyeOffset.height))
        }
        // Geometry order: mouth, head, antenna, right eye, left eye.
        let parts = [mouth, .identity, antenna, eye(rightEyeCenter), eye(leftEyeCenter)]
        return zip(geo, parts).map { flat, part in
            path(flat, part.concatenating(head).concatenating(toView))
        }
    }

    private static func interpolatedGeometry(weight: CGFloat) -> [[CGFloat]] {
        let (a, b, f): ([[CGFloat]], [[CGFloat]], CGFloat) = weight < 0.5
            ? (WowieGeometry.ultralight, WowieGeometry.regular, weight * 2)
            : (WowieGeometry.regular, WowieGeometry.black, (weight - 0.5) * 2)
        return zip(a, b).map { pa, pb in zip(pa, pb).map { $0 + ($1 - $0) * f } }
    }

    private static func path(_ flat: [CGFloat], _ t: CGAffineTransform) -> Path {
        func pt(_ i: Int) -> CGPoint { CGPoint(x: flat[i], y: flat[i + 1]).applying(t) }
        var p = Path()
        p.move(to: pt(0))
        var i = 2
        while i + 5 < flat.count {
            p.addCurve(to: pt(i + 4), control1: pt(i), control2: pt(i + 2))
            i += 6
        }
        p.closeSubpath()
        return p
    }
}

#Preview("WowieAvatar") {
    @Previewable @State var animation: WowieAnimation? = .typing
    @Previewable @State var weight: CGFloat = 0.5
    VStack(spacing: 16) {
        WowieAvatar(animation: animation, weight: weight)
            .frame(width: 160, height: 160)
        HStack {
            ForEach(WowieAnimation.allCases) { a in
                Button(a.rawValue) { animation = a }
            }
            Button("none") { animation = nil }
        }
        Slider(value: $weight, in: 0...1) { Text("Weight") }
        HStack(spacing: 12) {
            ForEach(WowieAnimation.allCases) { a in
                WowieAvatar(animation: a, weight: weight).frame(width: 40, height: 40)
            }
            Image.wowie.font(.system(size: 30))
        }
    }
    .padding()
}
