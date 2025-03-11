//
//  Image.swift
//  Core
//
//  Created by Nate Parrott on 3/9/25.
//

import QuartzCore

#if os(iOS)
import UIKit

extension UIGraphicsImageRendererFormat {
    static var scaleOf1: UIGraphicsImageRendererFormat {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return fmt
    }
}

extension UIImage {
    convenience init?(sfSymbol: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        self.init(systemName: sfSymbol, withConfiguration: config)
    }

    func processed(_ callback: (UIGraphicsRendererContext, UIImage, CGRect) -> ()) -> UIImage {
        let rect = CGRect(origin: .zero, size: self.size)
        return UIGraphicsImageRenderer(bounds: rect, format: .scaleOf1).image { (ctx) in
            callback(ctx, self, rect)
        }
    }

    static func empty(size: CGSize) -> UIImage {
        return UIGraphicsImageRenderer(size: size, format: .scaleOf1).image { (_) in
            // do nothing
        }
    }
}

#endif

extension UINSImage {
    func resized(toSize size: CGSize, scale: CGFloat? = nil) -> UINSImage {
        #if os(macOS)
        fatalError()
        #else
        let format = UIGraphicsImageRendererFormat.default()
        if let s = scale {
            format.scale = s
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
    }
    
    func resized(toMaximumDimension dimension: CGFloat, scaleFactor: CGFloat? = nil) -> UINSImage {
        let scale = min(dimension / size.width, dimension / size.height)
        let newSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        return resized(toSize: newSize, scale: scaleFactor)
    }

    func aspectResize(toSize size: CGSize) -> UINSImage {
#if os(macOS)
fatalError()
#else
        let format = UIGraphicsImageRendererFormat.default()
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let imageSize = self.size
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let drawAtSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = CGRect(origin: .init(x: (size.width - drawAtSize.width) / 2, y: (size.height - drawAtSize.height) / 2), size: drawAtSize)
            self.draw(in: rect)
        }
        #endif
    }
}
