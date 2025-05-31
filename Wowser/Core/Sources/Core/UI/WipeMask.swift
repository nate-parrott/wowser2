import SwiftUI

extension AnyTransition {
    static var wipeAway: AnyTransition {
        .modifier(active: WipeMask(revealProgress: 0), identity: WipeMask(revealProgress: 1))
    }
}

struct WipeMask: ViewModifier {
    var revealProgress: CGFloat = 1
    var wipeWidth: CGFloat = 0.7

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: geo.size.width)

                    LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: wipeWidth * geo.size.width)

                    Color.black
                        .frame(width: geo.size.width)
                }
                .frame(width: geo.size.width * (2 + wipeWidth), height: geo.size.height)
                .offset(x: -geo.size.width * (1 + wipeWidth) * revealProgress, y: 0)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}
