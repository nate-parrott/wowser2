//
//  CGAdditions.swift
//  ARRenderer
//
//  Created by Nate Parrott on 1/11/20.
//  Copyright © 2020 Nate Parrott. All rights reserved.
//

import QuartzCore

extension CGSize {
    var maxDimension: CGFloat {
        max(width, height)
    }
}

func remap(x: CGFloat, domainStart: CGFloat, domainEnd: CGFloat, rangeStart: CGFloat, rangeEnd: CGFloat) -> CGFloat {
    if domainStart == domainEnd {
        return rangeStart
    }
    let t = (x - domainStart) / (domainEnd - domainStart)
    return rangeStart + (rangeEnd - rangeStart) * t
}

func remapClamped(x: CGFloat, domainStart: CGFloat, domainEnd: CGFloat, rangeStart: CGFloat, rangeEnd: CGFloat) -> CGFloat {
    if domainStart == domainEnd {
        return rangeStart
    }
    let t = (x - domainStart) / (domainEnd - domainStart)
    let t2 = max(0, min(1, t))
    return rangeStart + (rangeEnd - rangeStart) * t2
}

extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    var center: CGPoint {
        .init(x: midX, y: midY)
    }
}

extension CGFloat {
    func roundToNearest(_ vals: [CGFloat]) -> CGFloat {
        // TODO: can be done more efficiently
        vals.sorted(key: { abs($0 - self) }).first ?? self
    }
}
