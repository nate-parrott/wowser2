import SwiftUI

// MARK: - Tab Button Style
public struct TabButtonStyle: ButtonStyle {
    let isActive: Bool
    
    public init(isActive: Bool = false) {
        self.isActive = isActive
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(isActive ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        configuration.isPressed
                        ? Color.gray.opacity(0.3)
                        : (isActive ? Color.gray.opacity(0.2) : Color.clear)
                    )
            )
    }
}

// MARK: - Sidebar Button Style
public struct SidebarButtonStyle: ButtonStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(configuration.isPressed ? .primary : .secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.gray.opacity(0.3) : Color.clear)
            )
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
public struct SearchResultButtonStyle: ButtonStyle {
    let isHighlighted: Bool
    
    public init(isHighlighted: Bool = false) {
        self.isHighlighted = isHighlighted
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(
                        configuration.isPressed
                        ? Color.accentColor.opacity(0.2)
                        : (isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
            )
    }
}

// MARK: - Button Style Extensions
public extension Button {
    func tabStyle(isActive: Bool = false) -> some View {
        self.buttonStyle(TabButtonStyle(isActive: isActive))
    }
    
    func sidebarStyle() -> some View {
        self.buttonStyle(SidebarButtonStyle())
    }
    
    func iconStyle() -> some View {
        self.buttonStyle(IconButtonStyle())
    }
    
    func searchResultStyle(isHighlighted: Bool = false) -> some View {
        self.buttonStyle(SearchResultButtonStyle(isHighlighted: isHighlighted))
    }
}