import SwiftUI

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
                if let toast = snapshot.toast {
                    ToastView(toast: toast) {
                        // Close action
                        BrowserStore.shared.modify { state in
                            state.removeToast(id: toast.id, in: windowID)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id) // Important for transitions when toast changes
                    .onAppear {
                        // Auto-dismiss after 5 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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
            .frame(maxWidth: 300)
            .padding([.top, .trailing], 8)
        }
    }
}

private struct ToastView: View {
    let toast: Toast
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            Text(toast.message)
                .font(.system(size: 13))
                .lineLimit(2)
            
            Spacer()
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .help("Close")
                    .frame(both: 28)
            }
        }
        .buttonStyle(GhostButtonStyle())
        .padding(8)
        .background {
            Color.white.opacity(0.01)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
        }
    }
}
