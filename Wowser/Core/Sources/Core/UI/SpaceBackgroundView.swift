import SwiftUI
import Combine
import CoreImage

// MARK: - Sidebar region reporting

enum SpaceBackgroundRegionEdge: Equatable {
    case top, bottom
}

/// Collects the frames (in `BrowserWindowRoot` space) of sidebar content
/// blocks per window, so the space background image knows what sits over its
/// top-left and bottom-left and can blur just those areas.
final class SpaceBackgroundRegions: ObservableObject {
    static let shared = SpaceBackgroundRegions()

    struct Entry: Equatable {
        var edge: SpaceBackgroundRegionEdge
        var rect: CGRect
    }

    @Published private(set) var entries = [ID<WindowState>: [String: Entry]]()

    func set(windowID: ID<WindowState>, key: String, edge: SpaceBackgroundRegionEdge, rect: CGRect) {
        let entry = Entry(edge: edge, rect: rect)
        guard entries[windowID]?[key] != entry else { return }
        entries[windowID, default: [:]][key] = entry
    }

    func remove(windowID: ID<WindowState>, key: String) {
        guard entries[windowID]?[key] != nil else { return }
        entries[windowID]?[key] = nil
    }

    /// Union of reported rects per edge. The profile carousel reports frames
    /// for offscreen pages too, so only rects actually over the fixed sidebar
    /// (x within the sidebar's width) count.
    func rects(windowID: ID<WindowState>) -> (top: CGRect?, bottom: CGRect?) {
        var top: CGRect?
        var bottom: CGRect?
        for entry in (entries[windowID] ?? [:]).values {
            guard entry.rect.width > 1, entry.rect.height > 1 else { continue }
            guard entry.rect.midX > 0, entry.rect.midX < UIConstants.sidebarWidth else { continue }
            switch entry.edge {
            case .top: top = top.map { $0.union(entry.rect) } ?? entry.rect
            case .bottom: bottom = bottom.map { $0.union(entry.rect) } ?? entry.rect
            }
        }
        return (top, bottom)
    }
}

/// True inside a fixed (non-floating) sidebar, where content blocks should
/// report their frames for background-blur purposes. The floating sidebar has
/// its own material background, so it never reports.
private struct SidebarReportsBlurRegionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarReportsBlurRegions: Bool {
        get { self[SidebarReportsBlurRegionsKey.self] }
        set { self[SidebarReportsBlurRegionsKey.self] = newValue }
    }
}

private struct SpaceBackgroundRegionReporter: ViewModifier {
    var key: String
    var edge: SpaceBackgroundRegionEdge
    @Environment(\.windowID) private var windowID
    @Environment(\.sidebarReportsBlurRegions) private var enabled

    func body(content: Content) -> some View {
        content
            .measureFrame(coordinateSpace: .named("BrowserWindowRoot")) { frame in
                guard enabled, let windowID else { return }
                SpaceBackgroundRegions.shared.set(windowID: windowID, key: key, edge: edge, rect: frame)
            }
            .onDisappear {
                if let windowID {
                    SpaceBackgroundRegions.shared.remove(windowID: windowID, key: key)
                }
            }
    }
}

extension View {
    /// Marks a sidebar content block whose frame the space background should
    /// blur behind. `key` must be stable and unique per block.
    func reportsSpaceBackgroundRegion(_ key: String, edge: SpaceBackgroundRegionEdge) -> some View {
        modifier(SpaceBackgroundRegionReporter(key: key, edge: edge))
    }
}

// MARK: - Renderer

/// Everything the blur output depends on. Quantized before comparison so live
/// resizes and small layout jitters don't trigger recomputes.
struct SpaceBackgroundBlurInput: Equatable {
    var fileURL: URL
    var viewSize: CGSize
    var topRect: CGRect?
    var bottomRect: CGRect?

    var blurRects: [CGRect] { [topRect, bottomRect].compactMap { $0 } }

    func quantized() -> SpaceBackgroundBlurInput {
        func snap(_ v: CGFloat, up: Bool, step: CGFloat) -> CGFloat {
            (up ? ceil(v / step) : floor(v / step)) * step
        }
        func snapRect(_ r: CGRect?) -> CGRect? {
            guard let r else { return nil }
            // Snap outward so the blur never undershoots the content.
            let minX = snap(r.minX, up: false, step: 16), minY = snap(r.minY, up: false, step: 16)
            return CGRect(x: minX, y: minY,
                          width: snap(r.maxX, up: true, step: 16) - minX,
                          height: snap(r.maxY, up: true, step: 16) - minY)
        }
        var out = self
        out.viewSize = CGSize(width: snap(viewSize.width, up: true, step: 32),
                              height: snap(viewSize.height, up: true, step: 32))
        out.topRect = snapRect(topRect)
        out.bottomRect = snapRect(bottomRect)
        return out
    }
}

/// Renders the space background image with the sidebar regions blurred, via
/// Core Image: a feathered rect mask multiplied by a detail (edge-energy) map,
/// so flat/blank parts of the image smoothly receive no blur. Recomputes only
/// when the quantized input changes, debounced.
final class SpaceBackgroundRenderer: ObservableObject {
    struct DebugInfo: Equatable {
        var blurRects: [CGRect] // view coordinates, quantized
        var recomputeCount: Int
        var viewSize: CGSize
    }

    @Published private(set) var output: CGImage?
    @Published private(set) var debugInfo: DebugInfo?

    private var lastInput: SpaceBackgroundBlurInput?
    private var pendingWork: DispatchWorkItem?
    private var recomputeCount = 0
    private var cachedSource: (url: URL, image: CIImage)?
    private let queue = DispatchQueue(label: "SpaceBackgroundRenderer", qos: .userInitiated)
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    func request(_ rawInput: SpaceBackgroundBlurInput) {
        let input = rawInput.quantized()
        guard input != lastInput else { return }
        lastInput = input
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compute(input) }
        pendingWork = work
        // Debounce so drag-resizes and layout settles coalesce into one render.
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func compute(_ input: SpaceBackgroundBlurInput) {
        guard input.viewSize.width > 10, input.viewSize.height > 10 else { return }

        let source: CIImage
        if let cachedSource, cachedSource.url == input.fileURL {
            source = cachedSource.image
        } else if let loaded = CIImage(contentsOf: input.fileURL) {
            cachedSource = (input.fileURL, loaded)
            source = loaded
        } else {
            print("[SpaceBG] Could not load image at \(input.fileURL.path)")
            return
        }

        // Render at view size (capped) so blur rects map 1:1 onto pixels.
        let maxViewDim = max(input.viewSize.width, input.viewSize.height)
        let renderScale = min(1.0, 1600.0 / maxViewDim)
        let pixelSize = CGSize(width: round(input.viewSize.width * renderScale),
                               height: round(input.viewSize.height * renderScale))
        let pixelRect = CGRect(origin: .zero, size: pixelSize)

        // Aspect-fill the source into pixelRect, center-cropped.
        var img = source.transformed(by: .init(translationX: -source.extent.minX, y: -source.extent.minY))
        let fillScale = max(pixelSize.width / img.extent.width, pixelSize.height / img.extent.height)
        img = img.transformed(by: .init(scaleX: fillScale, y: fillScale))
        img = img.transformed(by: .init(
            translationX: -(img.extent.width - pixelSize.width) / 2,
            y: -(img.extent.height - pixelSize.height) / 2
        )).cropped(to: pixelRect)

        var result = img
        let rects = input.blurRects
        if !rects.isEmpty {
            // Detail map: edge energy, spread and boosted, so flat areas of the
            // image contribute ~0 blur radius and detailed areas ~full radius.
            let detail = img
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 8])
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12 * renderScale])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0),
                ])
                .applyingFilter("CIColorClamp")
                .cropped(to: pixelRect)

            // Feathered rect mask: white rects over black, gaussian-softened.
            var rectMask = CIImage(color: .black).cropped(to: pixelRect)
            for rect in rects {
                // View coords (top-left origin) → CI pixel coords (bottom-left).
                let ciRect = CGRect(
                    x: rect.minX * renderScale,
                    y: (input.viewSize.height - rect.maxY) * renderScale,
                    width: rect.width * renderScale,
                    height: rect.height * renderScale
                )
                guard ciRect.width > 0, ciRect.height > 0 else { continue }
                rectMask = CIImage(color: .white).cropped(to: ciRect).composited(over: rectMask)
            }
            rectMask = rectMask
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18 * renderScale])
                .cropped(to: pixelRect)

            let mask = detail.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: rectMask,
            ])
            result = img
                .clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask,
                    kCIInputRadiusKey: 22 * renderScale,
                ])
                .cropped(to: pixelRect)
        }

        guard let cgImage = Self.ciContext.createCGImage(result, from: pixelRect) else {
            print("[SpaceBG] CI render failed")
            return
        }

        recomputeCount += 1
        let count = recomputeCount
        print("[SpaceBG] recompute #\(count): view=\(Int(input.viewSize.width))x\(Int(input.viewSize.height)) blurRects=\(rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: " | "))")

        let debug = DebugInfo(blurRects: rects, recomputeCount: count, viewSize: input.viewSize)
        DispatchQueue.main.async {
            self.output = cgImage
            self.debugInfo = debug
        }
    }
}

// MARK: - View

/// Fills the window with the space's background image, blurring behind the
/// sidebar's top and bottom content regions.
struct SpaceBackgroundView: View {
    var info: SpaceImageInfo
    var windowID: ID<WindowState>

    @StateObject private var renderer = SpaceBackgroundRenderer()
    @ObservedObject private var regions = SpaceBackgroundRegions.shared
    @AppStorage(DefaultsKeys.spaceBackgroundDebugView.rawValue) private var debugView = false

    var body: some View {
        GeometryReader { geo in
            let (top, bottom) = regions.rects(windowID: windowID)
            let input = SpaceBackgroundBlurInput(
                fileURL: info.fileURL,
                viewSize: geo.size,
                topRect: top,
                bottomRect: bottom
            )
            ZStack(alignment: .topLeading) {
                if let output = renderer.output {
                    Image(decorative: output, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if debugView, let debug = renderer.debugInfo {
                    SpaceBackgroundDebugOverlay(debug: debug)
                }
            }
            .onAppearOrChange(of: input) { renderer.request($0) }
        }
        .clipped()
    }
}

private struct SpaceBackgroundDebugOverlay: View {
    var debug: SpaceBackgroundRenderer.DebugInfo

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(debug.blurRects.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .stroke(Color.red, lineWidth: 2)
                    .background(Color.red.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            Text("blur recompute #\(debug.recomputeCount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(6)
                .background(Color.red)
                .cornerRadius(5)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }
}
