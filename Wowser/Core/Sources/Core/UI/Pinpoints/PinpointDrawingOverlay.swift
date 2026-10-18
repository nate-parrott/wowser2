#if os(macOS)
import SwiftUI
import AppKit
import WebKit

/// Sits over a pane's web view. While the window's `pinpointDrawing` targets
/// this pane, the user can scribble on the page; Done snapshots the page with
/// the strokes on top and attaches it to the note. See Data/Pinpoints.swift.
struct PinpointDrawingOverlay: View {
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.windows[windowID]?.pinpointDrawing?.paneID == paneID
        } main: { drawing in
            if drawing {
                PinpointCanvas(paneID: paneID, windowID: windowID)
            }
        }
    }
}

private struct PinpointCanvas: View {
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>

    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var saving = false

    private static let strokeWidth: CGFloat = 4
    private static let strokeColor = NSColor.systemRed

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.white.opacity(0.001)
                    .overlay {
                        Path { path in
                            for stroke in strokes + [current] { Self.add(stroke, to: &path) }
                        }
                        .stroke(Color(nsColor: Self.strokeColor), style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round))
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { current.append($0.location) }
                            .onEnded { _ in
                                strokes.append(current)
                                current = []
                            }
                    )

                controls(size: geo.size)
                    .padding(.top, 10)
            }
            .overlay {
                Rectangle().strokeBorder(Color(nsColor: Self.strokeColor).opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func controls(size: CGSize) -> some View {
        HStack(spacing: 8) {
            Text("Add a drawing to this todo")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(action: { _ = strokes.popLast() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(strokes.isEmpty)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
            Button("Attach") { Task { await finish(size: size) } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
    }

    private static func add(_ stroke: [CGPoint], to path: inout Path) {
        guard let first = stroke.first else { return }
        path.move(to: first)
        if stroke.count == 1 {
            path.addLine(to: first) // a dot
        } else {
            for point in stroke.dropFirst() { path.addLine(to: point) }
        }
    }

    private func cancel() {
        BrowserStore.shared.modify { $0.finishPinpointDrawing(windowID: windowID, imagePath: nil) }
    }

    @MainActor
    private func finish(size: CGSize) async {
        saving = true
        defer { saving = false }
        var shot: NSImage?
        if let webview = BrowserStore.shared.existingWebContent(forId: paneID)?.wkWebview {
            shot = try? await webview.takeSnapshot(configuration: WKSnapshotConfiguration())
        }
        let png = Self.composite(page: shot, strokes: strokes, size: size)
        let path: String? = await Task.detached {
            guard let png else { return nil }
            return try? PinpointImages.save(png: png)
        }.value
        BrowserStore.shared.modify { $0.finishPinpointDrawing(windowID: windowID, imagePath: path) }
    }

    /// The page snapshot with the strokes drawn over it, as PNG. `size` is the
    /// canvas size, which matches the web view's bounds.
    private static func composite(page: NSImage?, strokes: [[CGPoint]], size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size, flipped: true) { rect in
            page?.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            strokeColor.setStroke()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                let path = NSBezierPath()
                path.lineWidth = strokeWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: first)
                for point in stroke.dropFirst() { path.line(to: point) }
                if stroke.count == 1 { path.line(to: first) }
                path.stroke()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
