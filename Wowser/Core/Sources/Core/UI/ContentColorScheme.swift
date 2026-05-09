import Foundation
import SwiftUI

struct ContentColorScheme: Equatable {
    var background: HSBA
    var foreground: HSBA
}

struct WithContentColorScheme: ViewModifier {
    var scheme: ContentColorScheme?
    
    func body(content: Content) -> some View {
        content
            .background(scheme?.background.color ?? Color("Background", bundle: .module))
            .foregroundColor(scheme?.foreground.color)
    }
}

extension WebContent.Info {
    var colorScheme: ContentColorScheme? {
        if isEmptyPage {
            return nil
        }
        if let url = committedURL ?? url, let nativePageKey = NativePageKey(url: url) {
            switch nativePageKey {
            case .terminal:
                // Black and white
                return .init(background: .init(hue: 0, saturation: 0, brightness: 0, alpha: 1), foreground: .init(hue: 0, saturation: 0, brightness: 0.95, alpha: 1))
            case .vscode, .vscodeLoading: () // fall thru -- this is a normal webview
            case .fileBrowser:
                return nil
            }
        }
        if let topColor {
            let fg = HSBA(hue: topColor.hue, saturation: 0.1, brightness: topColor.hsla.lightness < 0.65 ? 0.95 : 0.05, alpha: 1)
            return .init(background: topColor, foreground: fg)
        }
        return nil
    }
}

extension HSBA {
    var inverted: HSBA {
        // TODO: hue-flipping logic should match auto dark mode
        .init(hue: hue, saturation: saturation, brightness: 1 - brightness, alpha: 1)
    }
}
