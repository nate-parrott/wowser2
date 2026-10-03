import SwiftUI

// MARK: - Tab Button Style
//public struct TabButtonStyle: ButtonStyle {
//    let isActive: Bool
//    
//    public init(isActive: Bool = false) {
//        self.isActive = isActive
//    }
//    
//    public func makeBody(configuration: Configuration) -> some View {
//        configuration.label
//            .font(.system(size: 13))
//            .foregroundColor(isActive ? .primary : .secondary)
//            .frame(maxWidth: .infinity, alignment: .leading)
//            .background(
//                RoundedRectangle(cornerRadius: 6)
//                    .fill(
//                        configuration.isPressed
//                        ? Color.gray.opacity(0.3)
//                        : (isActive ? Color.gray.opacity(0.2) : Color.clear)
//                    )
//            )
//    }
//}

// MARK: - Sidebar Button Style
//public struct SidebarButtonStyle: ButtonStyle {
//    public init() {}
//    
//    public func makeBody(configuration: Configuration) -> some View {
//        configuration.label
//            .font(.system(size: 13))
//            .foregroundColor(configuration.isPressed ? .primary : .secondary)
//            .padding(.vertical, 6)
//            .padding(.horizontal, 8)
//            .background(
//                RoundedRectangle(cornerRadius: 6)
//                    .fill(configuration.isPressed ? Color.gray.opacity(0.3) : Color.clear)
//            )
//    }
//}

// MARK: - Big Sidebar Button Style
//public struct BigSidebarButtonStyle: ButtonStyle {
//    @State private var hovered = false
//    
//    public init() {}
//    
//    public func makeBody(configuration: Configuration) -> some View {
//        configuration.label
//            .frame(maxWidth: .infinity)
//            .padding(.vertical, 8)
//            .background(
//                RoundedRectangle(cornerRadius: 6)
//                    .fill(Color.primary)
//                    .opacity(hovered ? (configuration.isPressed ? 0.15 : 0.1) : 0)
//            )
//            .contentShape(Rectangle())
//            .onHover(perform: { self.hovered = $0 })
////            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
//            .animation(.niceDefault(duration: 0.12), value: hovered)
//    }
//}

struct GhostButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.33)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary)
                    .opacity(hovered && isEnabled ? 0.07 : 0)
                    .scaleEffect(configuration.isPressed ? 0.9 : 1)
                    .animation(.snappy, value: configuration.isPressed)
            }
            .contentShape(.rect)
            .onHover(perform: { self.hovered = $0 })
    }
}

// MARK: - Icon Button Style
public struct IconButtonStyle: ButtonStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .primary : .secondary)
            .contentShape(Rectangle())
    }
}

// MARK: - Search Result Button Style
struct SearchResultButtonStyle: ButtonStyle {
    var isHighlighted: Bool
    var desaturatedHighlight: Bool // e.g. direct-to-site results
    var highlightColor: Color? // overrides the accent when selected (e.g. black for terminal rows)
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    init(isHighlighted: Bool = false, desaturatedHighlight: Bool = false, highlightColor: Color? = nil) {
        self.isHighlighted = isHighlighted
        self.desaturatedHighlight = desaturatedHighlight
        self.highlightColor = highlightColor
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
//            .darkModeConditional({ v, dark in
//                let color: Color? = isHighlighted ? (dark ? Color.black : Color.white) : nil
//                v.foregroundColor(color)
//            })
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isHighlighted ? (highlightColor ?? Color.accentColor) : (hovered ? (highlightColor ?? Color.accentColor).opacity(0.1) : Color.clear)
                    )
                    .saturation(isHighlighted && desaturatedHighlight ? 0.2 : 1)
            )
            .foregroundColor(isHighlighted ? Color.white : nil)
            .colorScheme(isHighlighted ? ColorScheme.light : colorScheme) // force dark mode if highlighted so we get white text and a dark-tinted variant of the accent
            .contentShape(Rectangle())
            .onHover(perform: { self.hovered = $0 })
    }
}

public extension Button {
//    func tabStyle(isActive: Bool = false) -> some View {
//        self.buttonStyle(TabButtonStyle(isActive: isActive))
//    }
    
//    func sidebarStyle() -> some View {
//        self.buttonStyle(SidebarButtonStyle())
//    }
    
    func iconStyle() -> some View {
        self.buttonStyle(IconButtonStyle())
    }    
}

// cant be a real button b/c it breaks drag and drop on mac
struct TabStyleButtonModifier: ViewModifier {
    var isSelected: Bool
    var pressed: () -> Void
    
    func body(content: Content) -> some View {
        content
            .font(.system(size: isMobile() ? 16 : 13))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(isSelected ? .regular.tint(Color.accentColor) : .identity, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
//            .background{
//                if isSelected {
//                    RoundedRectangle(cornerRadius: 8, style: .continuous)
//                        .fill(
//                            LinearGradient(colors: [
//                                Color("TabBackground", bundle: .module),
//                                Color("TabBackground", bundle: .module).opacity(0.7),
//                            ], startPoint: .top, endPoint: .bottom)
//                        )
//                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
//                }
//            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                pressed()
            }
    }
}

struct CircleButtonStyle: ButtonStyle {
    @State private var hovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background {
                if hovered {
                    Circle()
                        .foregroundStyle(.primary)
                        .opacity(0.1)
                }
            }
            .onHover(perform: { self.hovered = $0 })
    }
}

enum FreeformButtonState: Equatable {
    case none
    case hovered
    case pressed
    case disabled
}

struct FreeformButton<C: View>: View {
    var action: () -> ()
    @ViewBuilder var content: (FreeformButtonState) -> C

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(FreeformButtonStyle(content: content))
    }
}

private struct FreeformButtonStyle<C: View>: ButtonStyle {
    @ViewBuilder var content: (FreeformButtonState) -> C
    
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        content(state(pressed: configuration.isPressed))
            .onHover(perform: { self.hovered = $0 })
    }
    
    func state(pressed: Bool) -> FreeformButtonState {
        if !enabled { return .disabled }
        if pressed { return .pressed }
        return hovered ? .hovered : .none
    }
}
