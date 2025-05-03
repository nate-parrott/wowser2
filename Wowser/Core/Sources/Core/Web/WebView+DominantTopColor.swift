import Foundation
import WebKit

// MARK: - Web Page Dominant Color Extraction
private extension DispatchQueue {
    static let pageColorQueue = DispatchQueue(label: "com.wowser.pageColorQueue", qos: .userInitiated)
}

extension WKWebView {
    /// Captures the top portion of the web page and extracts the dominant color
    func extractTopDominantColor() async -> HSBA? {
        // Capture only the top portion (2 rows of pixels)
        let height: CGFloat = 2
        let captureRect = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        
        let config = WKSnapshotConfiguration()
        config.rect = captureRect
        
        do {
            let snapshot = try await takeSnapshot(configuration: config).cgImage(forProposedRect: nil, context: nil, hints: nil)
            
            return await withCheckedContinuation { continuation in
                DispatchQueue.pageColorQueue.async {
                    do {
                        guard let dominantColors = try snapshot?.dominantColors() else {
                            throw DominantColorsError.cantCaptureImage
                        }
                        if let primaryColor = dominantColors.first {
                            let hsba = NSColor(cgColor: primaryColor)?.hsba
                            continuation.resume(returning: hsba)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        print("Error extracting dominant color: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        } catch {
            print("Error taking snapshot: \(error)")
            return nil
        }
    }
}

private enum DominantColorsError: Error {
    case cantCaptureImage
}
