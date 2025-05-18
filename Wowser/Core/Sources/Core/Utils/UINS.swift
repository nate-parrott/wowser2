//
//  UINS.swift
//  Core
//
//  Created by Nate Parrott on 3/9/25.
//

import SwiftUI

#if os(macOS)
import AppKit
public typealias UINSView = NSView
public typealias UINSColor = NSColor
public typealias UINSImage = NSImage
public typealias UINSFont = NSFont
#else
import UIKit
public typealias UINSView = UIView
public typealias UINSColor = UIColor
public typealias UINSImage = UIImage
public typealias UINSFont = UIFont
#endif

extension UINSView {
    var colorScheme: ColorScheme {
        #if os(iOS)
        return traitCollection.userInterfaceStyle == .dark ? .dark : .light
#else
        return effectiveAppearance.name == .darkAqua ? .dark : .light
        #endif
    }
}

extension UINSColor {
    var swiftUI: Color {
        #if os(iOS)
        return Color(uiColor: self)
        #else
        return Color(nsColor: self)
        #endif
    }
}
