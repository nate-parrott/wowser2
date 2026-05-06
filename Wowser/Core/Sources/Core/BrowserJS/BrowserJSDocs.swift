import Foundation

public enum BrowserJSDocs {
    public static var dts: String {
        if let url = Bundle.module.url(forResource: "BrowserJS", withExtension: "d.ts"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return "// BrowserJS.d.ts not bundled"
    }
}
