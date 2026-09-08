import WebKit
import Foundation

extension WKWebView {
    /// Downloads the content at `request` via URLSession (used for downloads
    /// WebKit can't drive itself) and opens a file-browser tab for the result.
    public func downloadUsingRequest(_ request: URLRequest, windowID: ID<WindowState>) {
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: request) { fileURL, response, error in
            guard let fileURL, let response, error == nil else {
                print("Download failed: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            let suggestedFilename = response.suggestedFilename ?? request.url?.lastPathComponent ?? "download"
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destinationURL = URL.unique(folder: downloadsURL, name: suggestedFilename)
            do {
                try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                let download = Download(
                    url: request.url ?? URL(string: "about:blank")!,
                    destinationURL: destinationURL,
                    suggestedFilename: suggestedFilename,
                    progress: 1.0,
                    estimatedSize: size,
                    currentSize: size,
                    status: .completed
                )
                DispatchQueue.main.async {
                    BrowserStore.shared.modify { state in
                        state.openDownloadTab(download, windowID: windowID)
                    }
                }
            } catch {
                print("Error saving downloaded file: \(error)")
            }
        }
        task.resume()
    }
}
