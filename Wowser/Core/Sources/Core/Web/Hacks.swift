import Foundation
import WebKit

public protocol Hacks {
    func fixPreferences(_ prefs: WKPreferences)
}

public enum GlobalHacks {
    public static var hacks: Hacks?
}

