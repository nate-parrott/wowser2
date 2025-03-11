import WebKit
import Foundation

extension WKWebView {
    func runAsync(js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation({ cont in
            DispatchQueue.main.async {
                self.evaluateJavaScript(js) { result, err in
                    if let err {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume(returning: result)
                    }
                }
            }
        })
    }
}

extension String {
    var wrappedInSelfCallingJSFunction: String {
        "(function() { \(self) })()"
    }
}


extension WKWebView {
    func safe_evaluateJavascript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                self.evaluateJavaScript(script) { resultOpt, errOpt in
                    if let errOpt {
                        cont.resume(throwing: errOpt)
                        return
                    }
                    cont.resume(returning: resultOpt)
                }
            }
        }
    }
}
