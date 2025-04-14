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
                Group {
                    if let toast = snapshot.toast {
                        ToastView(toast: toast) {
                            // Close action
                            BrowserStore.shared.modify { state in
                                state.removeToast(id: toast.id, in: windowID)
                            }
                        }
                        .transition(.move(edge: .bottom))
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
            
            Spacer()
            
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
