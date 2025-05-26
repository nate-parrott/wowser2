import SwiftUI

struct DraggableFruit: View {
    var dragVector: CGPoint = .zero
    var distFromFloor: CGFloat = 0
    var grabbed = false
    
    var body: some View {
        let shadowOpacity = remapClamped(x: distFromFloor, domainStart: 0, domainEnd: 100, rangeStart: 0.3, rangeEnd: 0)
        let shadowOffset: CGFloat = remapClamped(x: distFromFloor + (grabbed ? 10 : 0), domainStart: 0, domainEnd: 100, rangeStart: 0, rangeEnd: 30)
        
        GeometryReader { geo in
            let k: CGFloat = geo.size.width
            
//            RadialGradient(colors: [Color.black, Color.black.opacity(0)], center: .center, startRadius: k * 0.2, endRadius: k * 0.5)
////                .frame(width: k * 0.8, height: k * 0.4)
//                .position(x: k * 0.46, y: k * 0.8)
            
            // Contact shadow
            Ellipse()
                .fill(Color.black)
                .frame(width: k * 0.5, height: k * 0.17)
                .scaleEffect(grabbed ? 1.2 : 1)
                .opacity(grabbed ? 0.6 : 1)
                .position(x: k * 0.48, y: k * 0.83)
                .blur(radius: k * 0.05)
                .opacity(shadowOpacity)
                .offset(x: shadowOffset * 0.5, y: shadowOffset)
            
            ZStack {
                Image(.fruit)
                    .resizable()
                    .frame(width: k, height: k)
                
                Image(.leafLeft)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(leftLeafRotation, anchor: .bottomTrailing)
                    .frame(width: k * 0.305)
                    .position(x: k * 0.3, y: k * 0.27)
                
                Image(.leafRight)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(rightLeafRotation, anchor: .init(x: 0, y: 0.7))
                    .frame(width: k * 0.41)
                    .position(x: k * 0.7, y: k * 0.26)
            }
            .rotationEffect(mainRotation)
            .scaleEffect(grabbed ? 1.1 : 1)
//            .opacity(grabbed ? 0.7 : 1)
        }
        .animation(.interactiveSpring, value: dragVector)
        .animation(.interactiveSpring, value: grabbed)
    }
    
    var mainRotation: Angle {
        .degrees(remap(x: dragVector.x, domainStart: -1, domainEnd: 1, rangeStart: -15, rangeEnd: 15))
    }
    
    var leftLeafRotation: Angle {
        var degs: CGFloat = 0
        degs += remap(x: dragVector.y, domainStart: -1, domainEnd: 1, rangeStart: -40, rangeEnd: 40)
        degs += remap(x: dragVector.x, domainStart: -1, domainEnd: 1, rangeStart: 20, rangeEnd: -20)
        if grabbed {
            degs -= 5
        }
        return .degrees(degs)
//        .degrees(remap(x: dragVector.x, domainStart: -1, domainEnd: 1, rangeStart: -15, rangeEnd: 15))
    }
    
    var rightLeafRotation: Angle {
//        .degrees(remap(x: dragVector.x, domainStart: -1, domainEnd: 1, rangeStart: -15, rangeEnd: 15))
        var degs: CGFloat = 0
        if grabbed {
            degs -= 15
        }
        degs += remap(x: dragVector.y, domainStart: -1, domainEnd: 1, rangeStart: 30, rangeEnd: -30)
        degs += remap(x: dragVector.x, domainStart: -1, domainEnd: 1, rangeStart: 10, rangeEnd: -10)
        return .degrees(degs)
    }
}
