import Foundation
import SwiftUI
import WebKit

struct SelectorCandidate: Equatable, Codable, Identifiable {
    var selector: String
    var matchCount: Int
    
    var id: String { selector }
}

private enum SelectorPickerError: Error {
    case unexpectedResultType
}

extension WKWebView {
    //             guard let path = Bundle.module.url(forResource: "\(name).min", withExtension: "json") else {
    
    private func injectElementPickerLib() async throws {
        let path = Bundle.module.url(forResource: "elementPicker", withExtension: "js")!
        let jsSource = try String(contentsOf: path)
        _ = try await runAsync(js: jsSource)
    }
    
    /*
     interface SelectorDetails {
       selector: string;
       matchCount: number;
     }
     function selectorsForElementAtPoint(x: number, y: number): SelectorDetails[] {
       const element = document.elementFromPoint(x, y);
       if (!element) {
         return [];
       }
       const selector = generateSelectorList(element as HTMLElement);
       const selectorDetails: SelectorDetails[] = selector.map((s) => {
         const matches = document.querySelectorAll(s);
         return {
           selector: s,
           matchCount: matches.length,
         };
       }
       );
       return selectorDetails
     }

     (window as any).__selectors_for_pt = selectorsForElementAtPoint;
     */
    
    func selectors(atPoint point: CGPoint) async throws -> [SelectorCandidate] {
        try await injectElementPickerLib()

        let js = """
        (function() {
            const result = __selectors_for_pt(\(point.x), \(point.y));
            return result;
        })()
        """

        return try await evaluateJS(js, resultType: [SelectorCandidate].self)
    }
    
    func positionsForElementsMatchingSelector(_ selector: String, filterToViewBounds: Bool) async throws -> [CGRect] {
        let js = """
        (function() {
            try {
                const elements = document.querySelectorAll(\(selector.encodedAsJSONString));
                const rects = [];

                for (const element of elements) {
                    const rect = element.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0) {
                        rects.push([rect.x, rect.y, rect.width, rect.height]);
                    }
                }

                return rects;
            } catch (e) {
                return [];
            }
        })()
        """

        let rectsArray = try await evaluateJS(js, resultType: [[Double]].self)

        let rects = rectsArray.map { rect in
            CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }

        if filterToViewBounds {
            let viewportSize = CGSize(width: bounds.width, height: bounds.height)
            let viewportRect = CGRect(origin: .zero, size: viewportSize)
            return rects.filter { rect in
                viewportRect.intersects(rect)
            }
        } else {
            return rects
        }
    }
    
    func positionOfElementAtPoint(_ point: CGPoint) async throws -> CGRect? {
        let js = """
        (function() {
            const element = document.elementFromPoint(\(point.x), \(point.y));
            if (!element) return null;

            const rect = element.getBoundingClientRect();
            return [rect.x, rect.y, rect.width, rect.height];
        })()
        """

        if let rectArray = try? await evaluateJS(js, resultType: [Double].self) {
            return CGRect(x: rectArray[0], y: rectArray[1], width: rectArray[2], height: rectArray[3])
        }
        return nil
    }
}

// Overlay that renders boxes around elements that match the selector
private struct SelectorPreview: View {
    var selector: String
    var webContent: WebContent

    @State private var rects = [CGRect]()

    var body: some View {
        ZStack {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                HoverElementRect()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .onChange(of: selector) { _ in
            refreshRects()
            print("Selector changed to \(selector)")
        }
        .onAppear {
            refreshRects()
        }
    }

    private func refreshRects() {
        Task { @MainActor in
            do {
                let newRects = try await webContent.wkWebviewForPicker.positionsForElementsMatchingSelector(selector, filterToViewBounds: true)
                DispatchQueue.main.async {
                    self.rects = newRects
                }
            } catch {
                print("Error getting positions for selector: \(error)")
            }
        }
    }
}

private struct HoverElementRect: View {
    var body: some View {
        Color.yellow.blendMode(.multiply)
            .opacity(0.3)
            .overlay {
                Rectangle().stroke(Color.yellow).brightness(-0.3)
            }
    }
}

// Overlay that draws a box over the hovered element.
private struct HoveredElementPreview: View {
    var point: CGPoint
    var webContent: WebContent

    @StateObject private var coordinator = Coordinator()

    var body: some View {
        ZStack {
            if let rect = coordinator.fetchedRect {
                HoverElementRect()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .onChange(of: point) { _ in
            fetchElementRect()
        }
        .onAppear {
            fetchElementRect()
        }
    }

    private func fetchElementRect() {
        if coordinator.fetching {
            coordinator.needsFetchAfter = true
            return
        }

        coordinator.fetching = true

        Task { @MainActor in
            do {
                let rect = try await webContent.wkWebviewForPicker.positionOfElementAtPoint(point)

                DispatchQueue.main.async {
                    coordinator.fetchedRect = rect
                    coordinator.fetching = false

                    if coordinator.needsFetchAfter {
                        coordinator.needsFetchAfter = false
                        fetchElementRect()
                    }
                }
            } catch {
                print("Error getting element position: \(error)")
                DispatchQueue.main.async {
                    coordinator.fetching = false
                }
            }
        }
    }

    private class Coordinator: ObservableObject {
        var fetching = false
        var needsFetchAfter = false
        @Published var fetchedRect: CGRect?
    }
}

//private struct SelectorRefineSlider: View {
//    @Binding var val: CGFloat // 0..1
//    var selector: String
//    var matchCount: Int
//    var onClick: () -> Void // When user clicks on slider bar, we're done.
//}

// Used to let picking a selector
struct ElementPickerOverlay: View {
    var webContent: WebContent
    var onDone: (String?) -> Void

    enum Status: Equatable {
        case picking
        case refining(clickPt: CGPoint, candidates: [SelectorCandidate], normalizedDragDist: CGFloat)
    }

    @State private var status = Status.picking
    @State private var mousePosition = CGPoint.zero
    @State private var isDragging = false
    @State private var dragStartLocation = CGPoint.zero
    /// Selector fetch kicked off on mouse-down; awaited on mouse-up so a quick
    /// click still completes even if the JS hasn't returned yet.
    @State private var pendingCandidates: Task<[SelectorCandidate], Error>?

    var body: some View {
        GeometryReader { geo in
            ZStack {

                // Render appropriate overlays based on status
                Group {
                    switch status {
                    case .picking:
                        HoveredElementPreview(point: mousePosition, webContent: webContent)
                            .allowsHitTesting(false)

                    case .refining(let pt, _, _):
                        // Render selected item dot
                        Circle().fill(Color.yellow).frame(both: 6)
                            .frame(both: 1)
                            .position(x: pt.x, y: pt.y)
                        
                        // Show the current selector highlight
                        if let selectedCandidate {
                            SelectorPreview(selector: selectedCandidate.selector, webContent: webContent)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .allowsHitTesting(false)
                
                statusPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(40)
                    .allowsHitTesting(false)
                
                // Transparent overlay to catch mouse events
                Color.white.opacity(0.01)
                    .contentShape(Rectangle())
                    .trackMouseOutsideWindow { position, bounds in
                        if case .picking = status {
                            self.mousePosition = position
                        }
                    }
                    .gesture(dragGesture)
            }
        }
    }
    
    @ViewBuilder private var statusPill: some View {
        ZStack {
            switch status {
            case .picking:
                Text("Tap to pick or drag to refine")
                    .font(.system(size: 14, weight: .medium))
            case .refining(_, _, _):
                VStack {
                    Text("Drag outward to select more items")
                        .font(.system(size: 12, weight: .bold))
                    
                    if let selectedCandidate {
                        Text(selectedCandidate.selector)
                            .lineLimit(2)
                            .font(.system(size: 12, design: .monospaced))
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .frame(width: 300)
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule(style: .continuous).fill(Color.yellow).brightness(-0.2))
        .shadow(color: Color.black.opacity(0.1), radius: 12, x: 0, y: 2)
    }
    
    private var selectedCandidate: SelectorCandidate? {
        if case .refining(_, let candidates, let normalizedDragDist) = status {
            return candidate(in: candidates, normalizedDragDist: normalizedDragDist)
        }
        return nil
    }
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartLocation = value.startLocation

                    if case .picking = status {
                        beginPick(at: value.startLocation)
                    }
                }

                if case .refining(let clickPt, let candidates, _) = status {
                    let dist = normalizedDragDist(from: dragStartLocation, to: value.location)
                    status = .refining(clickPt: clickPt, candidates: candidates, normalizedDragDist: dist)
                }
            }
            .onEnded { value in
                isDragging = false
                let dist = normalizedDragDist(from: dragStartLocation, to: value.location)
                finishPick(normalizedDragDist: dist)
            }
    }

    /// Drag distance mapped to 0...1 over ~300pt, with a 10pt dead zone so a
    /// plain click selects the most specific candidate.
    private func normalizedDragDist(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dragDistance = hypot(end.x - start.x, end.y - start.y)
        return max(0, min(1, (dragDistance - 10) / 300))
    }

    private func candidate(in candidates: [SelectorCandidate], normalizedDragDist: CGFloat) -> SelectorCandidate? {
        if candidates.count <= 1 {
            return candidates.first
        }
        let index = min(candidates.count - 1, Int(normalizedDragDist * CGFloat(candidates.count - 1)))
        return candidates.get(index)
    }

    /// Mouse-down: start fetching candidates for the element under the cursor.
    /// Once they arrive we enter `.refining` so the highlight tracks the drag.
    private func beginPick(at location: CGPoint) {
        mousePosition = location

        let task = Task { @MainActor in
            let candidates = try await webContent.wkWebviewForPicker.selectors(atPoint: location)
            // Most specific (fewest matches) first
            return candidates.sorted { $0.matchCount < $1.matchCount }
        }
        pendingCandidates = task

        Task { @MainActor in
            guard let candidates = try? await task.value, pendingCandidates == task else { return }
            if case .picking = status {
                let dist = isDragging ? normalizedDragDist(from: dragStartLocation, to: mousePosition) : 0
                status = .refining(clickPt: location, candidates: candidates, normalizedDragDist: dist)
            }
        }
    }

    /// Mouse-up: wait for the candidates (if still in flight) and report the
    /// one at the current drag distance.
    private func finishPick(normalizedDragDist: CGFloat) {
        guard let task = pendingCandidates else { return }
        pendingCandidates = nil

        Task { @MainActor in
            do {
                let candidates = try await task.value
                if let picked = candidate(in: candidates, normalizedDragDist: normalizedDragDist) {
                    onDone(picked.selector)
                } else {
                    status = .picking
                }
            } catch {
                print("Error getting selectors: \(error)")
                status = .picking
            }
        }
    }
}

private enum ElementPickerError: Error {
    case webKitOnly
}

private extension WebContent {
    /// The element picker drives the page via WebKit JS helpers; Chromium tabs
    /// aren't supported yet.
    var wkWebviewForPicker: WebContentWebView {
        get throws {
            guard let wkWebview else { throw ElementPickerError.webKitOnly }
            return wkWebview
        }
    }
}
