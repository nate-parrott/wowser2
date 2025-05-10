import SwiftUI

struct BorderedToolbarButton: View {
    var label: String
    var icon: Image?
    var filled: Bool = true
    var action: () -> Void

    var body: some View {
        FreeformButton(action: action) { state in
            let pressed = state == .pressed
            let hovered = state == .hovered
            content
                .padding(.trailing, 4)
                .padding(.leading, icon != nil ? 2 : 4)
                .padding(.vertical, 2)
                .opacity(filled ? 0 : 1) // if filled, will be drawn using mask
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .reverseMask {
                                content
                            }
                    } else {
                        // Fake border so we can use the .tint fill
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .reverseMask {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).padding(1)
                            }
                    }
                }
                .accessibilityLabel(Text(label))
                .foregroundStyle(.tint)
                .opacity(pressed ? 0.5 : 1)
                .opacity(hovered && !pressed ? 0.9 : 1)
                .padding(.vertical, 12)
                .contentShape(.rect)
                .opacity(state == .disabled ? 0.3 : 1)
        }
    }

    @ViewBuilder var content: some View {
        HStack(spacing: 4) {
            if let icon {
                icon
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
        }
        .textCase(.uppercase)
        .font(.system(size: 10, weight: .semibold))
    }
}
