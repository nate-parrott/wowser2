import Reeeed
import SwiftUI

//extension ReaderTheme {
//    static let serif: ReaderTheme = .init(background: UIColor(named: "FeedBackground")!, link: UIColor(named: "AccentRed")!, additionalCSS: """
//    body > *, h1, h2, h3, h4, h5, h6 {
//        font-family: "Iowan Old Style", serif;
//    }
//""")
//}

//Headers:
//SF heavy, Avenir Heavy, Helvetica Normal,  Futura Medium,  Iowan Old Style normal, Helvetica Neue Condensed bold
//
//Body:
//Sf normal,  Helvetica normal, Avenir normal, Courier normal, Iowan Old Style normal

// Stored in PreferenceStore
struct ReaderThemePref: Equatable, Codable {
    enum HeaderFont: String, Equatable, Codable, CaseIterable {
        case modern
        case avenir
        case helvetica
        case futura
        case iowan
        case baskerville
        case helveticaNeue

        var familyAndWeight: (String, String) {
            switch self {
            case .modern:
                return ("-apple-system", "800")
            case .avenir:
                return ("Avenir", "800")
            case .helvetica:
                return ("'Helvetica Neue'", "700")
            case .futura:
                return ("Futura", "regular")
            case .iowan:
                return ("'Iowan Old Style'", "normal")
            case .baskerville:
                return ("Baskerville", "bold")
            case .helveticaNeue:
                return ("HelveticaNeue-CondensedBold", "bold")
            }
        }

        var asSwiftUIFont: SwiftUI.Font {
            switch self {
            case .modern:
                return .system(.title).weight(.heavy)
            case .avenir:
                return .custom("Avenir-Heavy", size: 26)
            case .helvetica:
                return .custom("Helvetica", size: 34) // large
            case .futura:
                return .custom("Futura-Medium", size: 26)
            case .iowan:
                return .custom("IowanOldStyle-Roman", size: 34) // large
            case .baskerville:
                return .custom("Baskerville-Bold ", size: 34) // large
            case .helveticaNeue:
                return .custom("HelveticaNeue-CondensedBold", size: 34) // large
            }
        }

        // For feed cards
        var asSwiftUIFontSmall: SwiftUI.Font {
            switch self {
            case .modern:
                return .system(.title).weight(.heavy)
            case .avenir:
                return .custom("Avenir-Heavy", size: 22)
            case .helvetica:
                return .custom("Helvetica", size: 22) // large
            case .futura:
                return .custom("Futura-Medium", size: 22)
            case .iowan:
                return .custom("IowanOldStyle-Roman", size: 22) // large
            case .baskerville:
                return .custom("Baskerville-Bold ", size: 22) // large
            case .helveticaNeue:
                return .custom("HelveticaNeue-CondensedBold", size: 22) // large
            }
        }

        var asFamily: String {
            familyAndWeight.0
        }

        var weight: String {
            familyAndWeight.1
        }

        var titleSize: String? {
            switch self {
            case .baskerville, .helvetica, .helveticaNeue, .iowan:
                return "2em"
            default: return nil
            }
        }
    }
    var headerFont: HeaderFont = .iowan

    enum Font: String, Equatable, Codable, CaseIterable {
        case modern
        case avenir
        case helvetica
        case courier
        case iowan

        var asFamily: String {
            switch self {
            case .modern:
                return "-apple-system"
            case .avenir:
                return "Avenir"
            case .helvetica:
                return "Helvetica"
            case .courier:
                return "Courier"
            case .iowan:
                return "'Iowan Old Style'"
            }
        }

        var asSwiftUIFont: SwiftUI.Font {
            switch self {
            case .modern:
                return .system(.body)
            case .avenir:
                return .custom("Avenir-Heavy", size: 17)
            case .helvetica:
                return .custom("Helvetica", size: 17)
            case .iowan:
                return .custom("IowanOldStyle-Roman", size: 17)
            case .courier:
                return .custom("Courier", size: 17)
            }
        }
    }
    var font: Font = .modern

    enum ColorMode: String, Equatable, Codable, CaseIterable {
        case auto
        case dark
        case light
    }
    var colorMode = ColorMode.auto

    var colorSchemeOverride: ColorScheme? {
        switch colorMode {
        case .auto:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }

    enum Size: String, Equatable, Codable, CaseIterable {
        case xs
        case small
        case normal
        case large
        case xl

        var emSize: Double {
            switch self {
            case .xs:
                return 0.85
            case .small:
                return 0.93
            case .normal:
                return 1
            case .large:
                return 1.07
            case .xl:
                return 1.15
            }
        }
    }
    var size = Size.normal

    enum LineSpacing: String, Equatable, Codable, CaseIterable {
        case pct125
        case pct150
        case pct175
        case pct200

        var cssValue: String {
            switch self {
            case .pct125:
                return "1.25"
            case .pct150:
                return "1.5"
            case .pct175:
                return "1.75"
            case .pct200:
                return "2.0"
            }
        }

        var displayString: String {
            switch self {
            case .pct125:
                return "125%"
            case .pct150:
                return "150%"
            case .pct175:
                return "175%"
            case .pct200:
                return "200%"
            }
        }

        var swiftLineSpacing: CGFloat {
            let base: CGFloat = 17
            switch self {
            case .pct125:
                return base * 1.25 - base
            case .pct150:
                return base * 1.5 - base
            case .pct175:
                return base * 1.75 - base
            case .pct200:
                return base * 2 - base
            }
        }
    }

    var lineSpacing: LineSpacing = .pct175

    enum Flavor: String, Equatable, Codable, CaseIterable {
        case normal
        case warm
        case cool
        case highContrast

        var displayString: String {
            switch self {
            case .normal:
                return "Normal"
            case .warm: return "Warm"
            case .cool:
                return "Cool"
            case .highContrast:
                return "High Contrast"
            }
        }
    }
    var flavor: Flavor = .warm

    enum ColorKey: String, Hashable {
        case foreground
        case foreground2
        case background
        case background2
        case link
    }

    func color(forKey key: ColorKey) -> UINSColor {
        switch flavor {
//        case .normal:
//            switch key {
//            case .foreground:
//                return UINSColor(named: "Foreground", bundle: .module)!
//            case .foreground2:
//                return UINSColor(named: "Foreground2", bundle: .module)!
//            case .background:
//                return UINSColor(named: "Background", bundle: .module)!
//            case .background2:
//                return UINSColor(named: "Background2", bundle: .module)!
//            case .link:
//                return UINSColor(named: "AccentRed", bundle: .module)!
//            }
        case .warm, .normal, .cool, .highContrast:
            switch key {
            case .foreground:
                return UINSColor(named: "SoftFG", bundle: .module)!
            case .foreground2:
                return UINSColor(named: "SoftFG2", bundle: .module)!
            case .background:
                return UINSColor(named: "SoftBG", bundle: .module)!
            case .background2:
                return UINSColor(named: "SoftBG2", bundle: .module)!
            case .link:
                return UINSColor(named: "SoftLink", bundle: .module)!
            }
//        case .cool:
//            switch key {
//            case .foreground:
//                return UINSColor(named: "CoolFG", bundle: .module)!
//            case .foreground2:
//                return UINSColor(named: "CoolFG2", bundle: .module)!
//            case .background:
//                return UINSColor(named: "CoolBG", bundle: .module)!
//            case .background2:
//                return UINSColor(named: "CoolBG2", bundle: .module)!
//            case .link:
//                return UINSColor(named: "CoolLink", bundle: .module)!
//            }
//        case .highContrast:
//            switch key {
//            case .foreground:
//                return UINSColor(named: "HiCFG", bundle: .module)!
//            case .foreground2:
//                return UINSColor(named: "HiCFG2", bundle: .module)!
//            case .background:
//                return UINSColor(named: "HiCBG", bundle: .module)!
//            case .background2:
//                return UINSColor(named: "HiCBG2", bundle: .module)!
//            case .link:
//                return UINSColor(named: "HiCLink", bundle: .module)!
//            }
        }
    }

    var asTheme: ReaderTheme {
        var theme = ReaderTheme()
        var cssLines = [String]()
        cssLines.append("""
            body {
                font-family: \(font.asFamily), sans-serif;
            }
        """)

        cssLines.append("""
        h1, h2, h3, h4, h5, h6 {
            font-family: \(headerFont.asFamily), sans-serif;
            font-weight: \(headerFont.weight);
        }
        """)

        if let titleSize = headerFont.titleSize {
            cssLines.append("#__title { font-size: \(titleSize); }")
        }


        cssLines.append("body { font-size: \(size.emSize)em; }")
        cssLines.append("#__content { line-height: \(lineSpacing.cssValue); }")

        theme.foreground = color(forKey: .foreground)
        theme.foreground2 = color(forKey: .foreground2)
        theme.background = color(forKey: .background)
        theme.background2 = color(forKey: .background2)
        theme.link = color(forKey: .link)

        theme.additionalCSS = cssLines.joined(separator: "\n")
        return theme
    }
}
