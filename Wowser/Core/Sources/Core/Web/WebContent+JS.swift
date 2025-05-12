import Foundation
import WebKit

extension WKWebView {
    func evaluateJS<T: Codable>(_ script: String, resultType: T.Type) async throws -> T {
        let any: Any? = try await withCheckedThrowingContinuation { @MainActor cont in
            self.evaluateJavaScript(script) { result, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                cont.resume(returning: result)
            }
        }
        guard let obj = any else {
            throw JSEvalError.noResult
        }
        return try await DispatchQueue.global().performAsyncThrowing {
            let jsonData = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(resultType, from: jsonData)
        }
    }
}

private enum JSEvalError: Error {
    case noResult
}
