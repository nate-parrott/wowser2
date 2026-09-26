import SwiftUI

struct FancyPlus: View {
    var windowID: ID<WindowState>
    @State private var hoveredOnSegment: Int?
    @State private var quickAction: NewMenuItem = .storedQuickAction
    @State private var overflowAnchor = FlippedAnchorView()

    private func hoverChanged(seg: Int, on: Bool) {
        if on {
            hoveredOnSegment = seg
        } else {
            if hoveredOnSegment == seg {
                hoveredOnSegment = nil
            }
        }
    }
    
    private enum Segment: Hashable {
        case action(NewMenuItem)
        case overflowMenu
        
        var iconAndLabel: (String, String) {
            switch self {
            case .action(let newMenuItem):
                return newMenuItem.iconAndLabel
            case .overflowMenu:
                return ("ellipsis", "New...")
            }
        }
    }
    
    private var segs: [Segment] {
        [
            Segment.action(quickAction),
            Segment.action(.tab),
            Segment.overflowMenu,
        ]
    }
    
    var centerSegWidth: CGFloat = 60
    var sideSegWidth: CGFloat = 36
    
    @ViewBuilder
    private func renderSeg(idx: Int, seg: Segment) -> some View {
        let visible = expanded || idx == 1
        let w: CGFloat = idx == 1 ? centerSegWidth : sideSegWidth
        
        Button(action: {
            switch seg {
            case .action(let newMenuItem):
                hoveredOnSegment = nil
                newMenuItem.perform(windowID: windowID)
            case .overflowMenu:
                showOverflowMenu()
            }
        }, label: {
            Image(systemName: seg.iconAndLabel.0)
                .help(seg.iconAndLabel.1)
                .frame(width: visible ? w : 0, height: 26)
                .contentShape(.rect)
//                .overlay(alignment: .leading) {
//                    if idx > 0 && expanded {
//                        Color.primary.opacity(0.1)
//                            .frame(width: 1)
//                    }
//                }
        })
        .opacity(visible ? 1 : 0)
        .background {
            if seg == .overflowMenu {
                MenuAnchor(view: overflowAnchor)
            }
        }
        .onHover(perform: { hoverChanged(seg: idx, on: $0) })
    }
    
    private func showOverflowMenu() {
        let menu = NewMenuItem.buildMenu(windowID: windowID) { item in
            guard item != .tab else { return }
            DefaultsKeys.newMenuQuickAction.setString(item.rawValue)
        }
        let bounds = overflowAnchor.bounds
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY + 4), in: overflowAnchor)
    }
    
    var cellWidth: CGFloat = 40
    var expanded: Bool {
        hoveredOnSegment != nil
    }
    
    private var glassAlignment: Alignment {
        if let hoveredOnSegment {
            switch hoveredOnSegment {
            case 0: return .leading
            case 1: return .center
            default: return .trailing
            }
        }
        return .center
    }
    
    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 0) {
            ForEach(segs.enumerated(), id: \.element) {
                renderSeg(idx: $0.offset, seg: $0.element)
            }
        }
        .background(alignment: glassAlignment) {
            if let hoveredOnSegment {
                Capsule(style: .continuous)
                    .glassEffect(Glass.regular.interactive())
                    .frame(width: hoveredOnSegment == 1 ? centerSegWidth : sideSegWidth)
                    .allowsHitTesting(false)
                    .padding(-2)
            }
        }
        .buttonStyle(.plain)
//        .background(Color.primary.opacity(0.05))
//        .clipShape(shape)
//        .overlay {
//            shape.stroke(lineWidth: 1.5)
//                .opacity(0.2)
//        }
        .background {
//            RecessedSidebarShape(shape: shape)
            shape.applyTabStyle(isSelected: false, isHovered: false)
        }
        .animation(.spring(duration: 0.22, bounce: 0.3, blendDuration: 0.1), value: hoveredOnSegment)
        .onHover {
            if !$0 {
                hoveredOnSegment = nil
            }
        }
        .padding(1)
        .onReceive(DefaultsKeys.newMenuQuickAction.publisher().map { _ in NewMenuItem.storedQuickAction }) {
            quickAction = $0
        }
//        HStack(spacing: 8) {
//            TabIconView(icon: .sfSymbol("plus"))
//                .accentColor(Color.primary)
//                .opacity(0.4)
////                .saturation(0)
////                .opacity(0.5)
//            Text("New Tab")
//                .opacity(0.4)
//                .lineLimit(1)
//            Spacer()
//            #if os(macOS)
//            NewNativeTabMenu(windowID: windowID)
//                .opacity(0.4)
//            #endif
//        }
//        .padding(.leading, isMobile() ? 14 : 8)
//        .padding(.trailing, 4)
//        .frame(height: isMobile() ? 44 : UIConstants.macTabHeight)
//        .contentShape(Rectangle())
//        .onHover { isHovered = $0 }
//        .modifier(TabStyleButtonModifier(isSelected: false, pressed: {
//            BrowserStore.shared.createTab(
//                withURL: nil,
//                in: windowID,
//                activate: true,
//                inCurrentSplit: isOpenInSplitViewModifierKeyPressed() || multiSelectModifierPressed()
//            )
//            // Show search overlay to enter URL
//            BrowserStore.shared.modify { state in
//                state.windows[windowID]?.searchOverlayActive = true
//            }
//        }))
    }
}

public struct FancyPlus_Previews: PreviewProvider {
    public static var previews: some View {
        Sidebar(floating: true)
            .frame(width: 200, height: 500)
            .withBrowserContext(
                windowID: ID<WindowState>(raw: "w0"),
                profileID: .defaultProfile
            )
    }
}
