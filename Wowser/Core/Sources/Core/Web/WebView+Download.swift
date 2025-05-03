import WebKit
import Foundation

extension WKWebView {
    /// Starts a download of the content at the given URL request
    /// - Parameters:
    ///   - request: The URL request to download
    ///   - windowID: The window ID where the download will be tracked
    public func downloadUsingRequest(_ request: URLRequest, windowID: ID<WindowState>) {
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        // Create a download task for the URL
        let task = session.downloadTask(with: request) { fileURL, response, error in
            guard let fileURL = fileURL,
                  let response = response,
                  error == nil else {
                print("Download failed: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            // Generate a suggested filename based on the response or URL
            let suggestedFilename = response.suggestedFilename ?? request.url?.lastPathComponent ?? "download"
            
            // Get downloads directory
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            
            // Create a unique destination path
            let destinationURL = URL.unique(folder: downloadsURL, name: suggestedFilename)
            
            do {
                // Create a unique download ID
                let downloadID = ID<Download>.assign()
                
                // Move the downloaded file to the destination
                try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                
                // Create the download object
                let download = Download(
                    id: downloadID,
                    url: request.url ?? URL(string: "about:blank")!,
                    destinationURL: destinationURL,
                    suggestedFilename: suggestedFilename,
                    progress: 1.0,
                    estimatedSize: (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0,
                    currentSize: (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0,
                    status: .completed
                )
                
                // Add the download to the browser store
                DispatchQueue.main.async {
                    BrowserStore.shared.modify { state in
                        state.windows[windowID]?.downloads[downloadID] = download
                    }
                }
                
                print("Downloaded file to: \(destinationURL.path)")
            } catch {
                print("Error saving downloaded file: \(error)")
            }
        }
        
        // Start the download
        task.resume()
    }
}