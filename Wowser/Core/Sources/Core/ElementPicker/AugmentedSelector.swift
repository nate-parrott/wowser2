import Foundation

/// Helpers for "augmented" selectors: CSS optionally extended with synthetic
/// computed-style selectors of the form `.__sss__<kind>__<field>__...`.
/// See element-picker/src/styleSelectors.ts for the grammar and resolution algorithm.
public enum AugmentedSelector {
    public static let stylePrefix = "__sss__"

    public static func containsStyleSelectors(_ selector: String) -> Bool {
        selector.contains("." + stylePrefix)
    }

    /// A self-invoking JS expression that evaluates to an `Array` of the elements
    /// matching `selector` in the current document.
    ///
    /// Plain CSS takes the hot path (`querySelectorAll`). Style selectors inline the
    /// small resolver bundle (once per page), which matches onscreen elements by
    /// computed style, tags them with temporary classes, runs `querySelectorAll`
    /// on the rewritten selector, then removes the classes.
    public static func matchesJS(for selector: String) -> String {
        let json = selector.encodedAsJSONString
        if !containsStyleSelectors(selector) {
            return "(function() { return Array.from(document.querySelectorAll(\(json))); })()"
        }
        return """
        (function() {
            if (typeof window.__sss_resolve !== 'function') {
                \(resolverSource)
            }
            return window.__sss_resolve(\(json));
        })()
        """
    }

    /// Source of element-picker's `styleSelectors` bundle, which defines `window.__sss_resolve`.
    static let resolverSource: String = {
        guard let url = Bundle.module.url(forResource: "styleSelectors", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("styleSelectors.js missing from bundle")
            return ""
        }
        return src
    }()
}
