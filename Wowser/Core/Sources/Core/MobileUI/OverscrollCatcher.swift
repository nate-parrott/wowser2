import SwiftUI

struct OverscrollCatcherOptions: Equatable {
    var vertical: Bool = false
    var horizontal: Bool = true
}

enum OverscrollState: Equatable {
    case atRest
    case overscrolled(offset: CGPoint /* positive if we swipe right/down */, draggingAtPos: CGPoint?)
}

#if os(iOS)
import UIKit

struct OverscrollCatcher<T: View>: UIViewControllerRepresentable {
    var options: OverscrollCatcherOptions
    var didReleaseDrag: ((OverscrollState) -> Void)?
    @ViewBuilder var fn: (OverscrollState) -> T
    
    typealias UIViewControllerType = OverscrollCatcherViewController<T>

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let vc = OverscrollCatcherViewController(view: fn(.atRest), options: options)
        vc.didReleaseDrag = didReleaseDrag
        vc.didChangeState = { [weak vc] state in
            vc?.swiftuiView = fn(state)
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
        uiViewController.options = options
        uiViewController.didReleaseDrag = didReleaseDrag
        uiViewController.didChangeState = { [weak uiViewController] state in
            uiViewController?.swiftuiView = fn(state)
        }
        uiViewController.swiftuiView = fn(uiViewController.state)
    }
}

class OverscrollCatcherViewController<T: View>: UIViewController, UIScrollViewDelegate {
    var didReleaseDrag: ((OverscrollState) -> Void)?
    var didChangeState: ((OverscrollState) -> Void)?
    var options: OverscrollCatcherOptions = .init() {
        didSet {
            if options != oldValue {
                _updatedOptions()
            }
        }
    }
    
    var swiftuiView: T {
        get { hostVC.rootView }
        set {
            hostVC.rootView = newValue
        }
    }
    
    let hostVC: UIHostingController<T>
    let scrollView: UIScrollView
    private(set) var state = OverscrollState.atRest {
        didSet {
            if state != oldValue {
                didChangeState?(state)
            }
        }
    }
    
    init(view: T, options: OverscrollCatcherOptions = .init()) {
        self.hostVC = UIHostingController(rootView: view)
        self.scrollView = UIScrollView()
        super.init(nibName: nil, bundle: nil)
        addChild(self.hostVC)
        self.view.addSubview(self.scrollView)
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.addSubview(self.hostVC.view)
        self.scrollView.delegate = self
        self.scrollView.clipsToBounds = false
        _updatedOptions()
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if !CGRectEqualToRect(self.scrollView.frame, view.bounds) {
            self.scrollView.frame = view.bounds
            self.scrollView.contentSize = view.bounds.size
        }
        hostVC.view.frame = self.scrollView.convert(self.view.bounds, from: self.view)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func _updatedOptions() {
        scrollView.alwaysBounceVertical = options.vertical
        scrollView.alwaysBounceHorizontal = options.horizontal
    }
    
    // MARK: - UIScrollViewDelegate
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.state = .overscrolled(offset: curOffset, draggingAtPos: scrollView.isDragging ? scrollView.panGestureRecognizer.location(in: scrollView) : nil)
        self.view.setNeedsLayout()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.didReleaseDrag?(self.state)
        
        if !decelerate {
            self.state = .atRest
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if !scrollView.isDragging {
            self.state = .atRest
        }
    }
    
    private var curOffset: CGPoint {
        return CGPoint(
            x: -scrollView.contentOffset.x * (options.horizontal ? 1 : 0),
            y:  -scrollView.contentOffset.y * (options.vertical ? 1 : 0)
        )
    }
}

struct OverscrollPreview: View {
    var body: some View {
        OverscrollCatcher(options: .init()) { state in
            Color.red
                .overlay {
                    if case .overscrolled(let offset, let draggingAtPos) = state, let draggingAtPos {
                        let committed = abs(offset.x) > 50
                        let back = offset.x > 0
                        let icon: String = back ? (committed ? "arrow.backward.circle.fill" : "arrow.backward") :
                        (committed ? "arrow.forward.circle.fill" : "arrow.forward")
                        BackForwardGestureIndicator(offset: offset, fingerPos: draggingAtPos, icon: icon, lockedIn: committed)
                            .onChange(of: committed) { newValue in
                                if newValue {
                                    Haptics.shared.performSelectionHaptic()
                                }
                            }
                    }
                }
        }
    }
}

struct DragToGoBackView<T: View>: View {
    var webContent: WebContent
    @ViewBuilder var view: () -> T
    var threshold: CGFloat = 50
    
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    
    var body: some View {
        OverscrollCatcher(options: .init(), didReleaseDrag: released(state:)) { state in
            view()
                .environment(\.windowID, windowID)
                .environment(\.profileID, profileID)
                .overlay {
                    if case .overscrolled(let offset, let draggingAtPos) = state, let draggingAtPos {
                        let committed = abs(offset.x) > threshold
                        let back = offset.x > 0
                        let icon: String = back ? (committed ? "arrow.backward.circle.fill" : "arrow.backward") :
                        (committed ? "arrow.forward.circle.fill" : "arrow.forward")
                        BackForwardGestureIndicator(offset: offset, fingerPos: draggingAtPos, icon: icon, lockedIn: committed)
                            .onChange(of: committed) { newValue in
                                if newValue {
                                    Haptics.shared.performSelectionHaptic()
                                }
                            }
                            .edgesIgnoringSafeArea(.all)
                    }
                }
        }
    }
    
    private func released(state: OverscrollState) {
        guard case .overscrolled(let offset, _) = state, abs(offset.x) > threshold else {
            return
        }
        if offset.x > 0 {
            // go back
            webContent.goBack()
        } else {
            webContent.goForward()
        }
    }
}

struct BackForwardGestureIndicator: View {
    var offset: CGPoint
    var fingerPos: CGPoint
    var icon: String = "questionmark.circle.fill"
    var lockedIn = false
    
//    @State private var lastFingerPos: CGPoint?
    
    var body: some View {
        Image(systemName: icon)
            .scaleEffect(lockedIn ? 1 : 0.8)
            .font(.system(size: 20, weight: .semibold))
            .opacity(lockedIn ? 1 : 0.66)
            .animation(.spring(response: 0.15, dampingFraction: 0.5, blendDuration: 0.05), value: lockedIn)
            .foregroundStyle(.white)
            .frame(both: 60)
            .background(alignment: offset.x > 0 ? .leading : .trailing) {
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .frame(width: 60 + abs(offset.x), height: 60)
            }
            .position(origPoint)
//            .onChange(of: fingerPos) { oldValue, newValue in
//                if newValue == nil {
//                    lastFingerPos = oldValue
//                }
//            }
    }
    
    var origPoint: CGPoint {
        let pos: CGPoint = fingerPos // ?? lastFingerPos ?? .zero
        let preOffset = CGPoint(x: pos.x - offset.x, y: pos.y - offset.y)
        return preOffset
    }
}

#Preview {
    OverscrollPreview()
}

#endif
