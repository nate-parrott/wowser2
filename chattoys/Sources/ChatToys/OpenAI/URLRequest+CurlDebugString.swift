import Foundation

extension URLRequest {
    /// Generates a properly-escaped curl command string for debugging purposes.
    /// This can be copied and pasted directly into a terminal to reproduce the request.
    var curlDebugString: String {
        var components = ["curl"]
        
        // Add HTTP method
        if let method = httpMethod, method != "GET" {
            components.append("-X \(method)")
        }
        
        // Add URL
        if let url = url {
            components.append("'\(url.absoluteString)'")
        }
        
        // Add headers
        if let headers = allHTTPHeaderFields {
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                let escapedValue = value.replacingOccurrences(of: "'", with: "'\\''")
                components.append("-H '\(key): \(escapedValue)'")
            }
        }
        
        // Add body
        if let httpBody = httpBody, let bodyString = String(data: httpBody, encoding: .utf8) {
            let escapedBody = bodyString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
            components.append("-d '\(escapedBody)'")
        }
        
        // Join with line continuations for readability
        return components.enumerated().map { index, component in
            index == 0 ? component : "  \(component)"
        }.joined(separator: " \\\n")
    }
}
