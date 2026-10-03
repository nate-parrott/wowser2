import SwiftUI

struct NewToastView: View {
    var toast: Toast
    var dismiss: () -> Void
    
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    
    var body: some View {
        ToastLike(icon: toast.icon) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    if let title = toast.title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(toast.message)
                }
                if let actions = toast.actions, !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                            Button(action.title) {
                                action.kind.perform()
                                // Remove without `onDismiss`: an action was taken.
                                if let windowID {
                                    BrowserStore.shared.modify { $0.removeToast(id: toast.id, in: windowID) }
                                }
                            }
                            .buttonStyle(ToastPillButtonStyle(prominent: idx == 0))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .help("Dismiss Message")
        }
    }
    
    @Environment(\.windowID) private var windowID: ID<WindowState>?
}

/// Text buttons on a toast (agent actions, "Forget" on the autofill toast).
/// The first one is filled with the accent color.
struct ToastPillButtonStyle: ButtonStyle {
    var prominent: Bool
    @State private var hovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(0.12))
                    .brightness(configuration.isPressed ? -0.1 : (hovered ? 0.05 : 0))
            }
            .onHover { hovered = $0 }
    }
}

// Standard component to use with ToastLike
struct ToastIconButtonStyle: ButtonStyle {
    var primary: Bool = false
    @State private var hovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        let pressAdjustOpacity: CGFloat = configuration.isPressed ? 0.1 : 0
        configuration.label
            .frame(both: 26)
            .fontWeight(.semibold)
            .background {
                Circle()
                    .fill(Color.primary)
                    .opacity(pressAdjustOpacity + (primary ? (hovered ? 0.35 : 0.2) : (hovered ? 0.15 : 0)))
            }
            .onHover(perform: { hovered = $0 })
    }
}

extension Animation {
    static let toastDropCurve: Animation = .spring(duration: 0.2, bounce: 0.4, blendDuration: 0.1)
}

// Standard component to use
struct ToastLike<B: View>: View {
    var icon: String? = nil
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var content: () -> B
    
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    
    var body: some View {
        let bgColor: Color = colorScheme == .dark ? Color.black : Color.white
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let grad = LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
        
        HStack(alignment: alignment) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(Color.white)
                    .frame(both: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
    //                .foregroundColor(.accentColor)
    //                .frame(both: 30)
    //                .background {
    //                    RoundedRectangle(cornerRadius: 8, style: .continuous)
    //                        .fill(Color.primary)
    //                        .opacity(0.15)
    //                }
                    .mask(grad)
                    .shadow(color: Color.accentColor.opacity(0.1), radius: 6, x: 0, y: 2)
            }
            
            content()
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(ToastIconButtonStyle(primary: true))
        .padding(10)
        .frame(width: 320)
        .background(shape.fill(bgColor).opacity(0.3))
        .glassEffect(.regular, in: shape)
    }
}

public struct ToastViewer: View {
    @Environment(\.windowID) private var windowID: ID<WindowState>?
    
    private struct ToastSnapshot: Equatable {
        let toast: Toast?
        
        init(state: BrowserState, windowID: ID<WindowState>) {
            self.toast = state.windows[windowID]?.currentToast
        }
    }
    
    public var body: some View {
        if let windowID {
            WithSnapshotMain(
                store: BrowserStore.shared,
                snapshot: { ToastSnapshot(state: $0, windowID: windowID) }
            ) { snapshot in
                Group {
                    if let toast = snapshot.toast {
                        NewToastView(toast: toast) {
                            // Close action
                            toast.onDismiss?.perform()
                            BrowserStore.shared.modify { state in
                                state.removeToast(id: toast.id, in: windowID)
                            }
                        }
                        .padding()
                        .transition(.move(edge: .top))
                        .id(toast.id) // Important for transitions when toast changes
                        .onAppear {
                            guard toast.sticky != true else { return }
                            // Auto-dismiss after 4 seconds (or the toast's own timeout)
                            DispatchQueue.main.asyncAfter(deadline: .now() + (toast.dismissAfter ?? 4)) {
                                // Check if this is still the current toast
                                if BrowserStore.shared.model.windows[windowID]?.currentToast?.id == toast.id {
                                    BrowserStore.shared.modify { state in
                                        state.removeToast(id: toast.id, in: windowID)
                                    }
                                }
                            }
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
        }
    }
}

private struct ToastView: View {
    let toast: Toast
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.system(size: 15, weight: .medium))
                .padding(.leading, 8)
                .lineLimit(1)
            
            Spacer()

            ForEach(toast.actions ?? []) { action in
                Button(action.title) {
                    action.kind.perform()
                    onClose()
                }
                .buttonStyle(ToastActionButtonStyle())
            }
            
            KeyboardHint(text: "ESC", bgOverride: Color.white)
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .help("Close")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GhostButtonStyle())
        }
        .foregroundColor(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background {
            ZStack {
                Color.accentColor
                                
                Color.red.blendMode(.colorBurn).opacity(0.2)
                
                LinearGradient(colors: [Color.white, Color.black], startPoint: .top, endPoint: .bottom)
                    .blendMode(.overlay)
                    .opacity(0.2)
            }
        }
        .overlay(alignment: .top) {
            Color.white.opacity(0.1)
                .frame(height: 0.5)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.07)], startPoint: .top, endPoint: .bottom)
                .brightness(-0.4)
                .frame(height: 16)
                .frame(height: 1, alignment: .bottom)
        }
    }
}

/// Small white pill buttons on a toast (e.g. "Forget", "Never for this site").
private struct ToastActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.35 : 0.2))
            }
            .overlay {
                Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            }
    }
}

struct KeyboardHint: View {
    var text: String
    var bgOverride: Color? = nil
    
    var body: some View {
        Text(text)
            .font(.caption)
            .kerning(0.2)
            .opacity(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bgOverride ?? Color.primary)
                    .opacity(0.15)
            }
    }
}

#Preview {
    NewToastView(toast: .init(message: "I am a short toast!", icon: "bolt.fill"), dismiss: {})
    
    NewToastView(toast: .init(message: "I am a toast and i am very long, and I am proud of it!!", icon: "bolt.fill"), dismiss: {})
    
    NewToastView(toast: {
        let target = AgentToastReplyTarget.agent(key: "preview")
        var t = Toast(message: "Ready to push 3 commits to main?", icon: "hand.raised.fill", actions: [
            ToastAction(title: "Push", kind: .agentReply(target: target, toast: "", choice: "Push")),
            ToastAction(title: "Not yet", kind: .agentReply(target: target, toast: "", choice: "Not yet")),
        ])
        t.title = "Fix login redirect"
        t.sticky = true
        return t
    }(), dismiss: {})
}
