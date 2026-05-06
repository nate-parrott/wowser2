import SwiftUI
import Combine

#if os(macOS)
import AppKit
#endif

extension View {
    /// Subscribe to `BrowserState.focusState(windowID:)` for the given window.
    /// No-op when `windowID` is nil.
    func onReceiveFocusSnap(windowID: ID<WindowState>?, perform action: @escaping (FocusSnap) -> Void) -> some View {
        modifier(OnReceiveFocusSnapModifier(windowID: windowID, action: action))
    }
}

private struct OnReceiveFocusSnapModifier: ViewModifier {
    let windowID: ID<WindowState>?
    let action: (FocusSnap) -> Void

    func body(content: Content) -> some View {
        if let windowID {
            content.onReceive(
                BrowserStore.shared.uiPublisher
                    .map { $0.focusState(windowID: windowID) }
                    .removeDuplicates(),
                perform: action
            )
        } else {
            content
        }
    }
}

#if os(macOS)

/// Wraps `content` in an NSView that KVOs its window's first-responder. When
/// any view in the wrapped subtree becomes/leaves first responder, fires
/// `state.didFocus` / `state.didLoseFocus` for `target`. Use to wire view→state
/// for elements that don't have their own becomeFirstResponder hook (SwiftUI
/// Tables, third-party NSViews like SwiftTerm).
struct WrapsContentReportingFirstResponder<Content: View>: NSViewRepresentable {
    let target: FocusTarget
    let content: Content

    init(target: FocusTarget, @ViewBuilder content: () -> Content) {
        self.target = target
        self.content = content()
    }

    func makeNSView(context: Context) -> FirstResponderObservingHost {
        let host = FirstResponderObservingHost()
        host.target = target
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        context.coordinator.hosting = hosting
        return host
    }

    func updateNSView(_ host: FirstResponderObservingHost, context: Context) {
        host.target = target
        context.coordinator.hosting?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

final class FirstResponderObservingHost: NSView {
    var target: FocusTarget? {
        didSet { rebind() }
    }
    private var subscription: AnyCancellable?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebind()
    }

    private func rebind() {
        subscription?.cancel()
        subscription = nil
        guard let window = self.window, let target = self.target else { return }
        subscription = window.publisher(for: \.firstResponder)
            .removeDuplicates(by: { $0 === $1 })
            .sink { [weak self] firstResponder in
                guard let self else { return }
                let inside = self.wowser_subtreeContains(firstResponder)
                BrowserStore.shared.modify { state in
                    if inside {
                        state.didFocus(target: target)
                    } else {
                        state.didLoseFocus(target: target)
                    }
                }
            }
    }
}

#endif
