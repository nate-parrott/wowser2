import Foundation
import WebKit
import Combine

public struct Download: Identifiable, Codable, Equatable {
    public let id: ID<Download>
    public let url: URL
    public let destinationURL: URL
    public let suggestedFilename: String
    public let startDate: Date
    public var progress: Double
    public var estimatedSize: Int64
    public var currentSize: Int64
    public var status: DownloadStatus
    public var error: String?
    
    public enum DownloadStatus: String, Codable {
        case inProgress
        case completed
        case failed
        case cancelled
    }
    
    public init(
        id: ID<Download>,
        url: URL,
        destinationURL: URL,
        suggestedFilename: String,
        startDate: Date = Date(),
        progress: Double = 0.0,
        estimatedSize: Int64 = 0,
        currentSize: Int64 = 0,
        status: DownloadStatus = .inProgress,
        error: String? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.suggestedFilename = suggestedFilename
        self.startDate = startDate
        self.progress = progress
        self.estimatedSize = estimatedSize
        self.currentSize = currentSize
        self.status = status
        self.error = error
    }
}

public class DownloadManager: NSObject, WKDownloadDelegate {
    
    // Singleton instance
    public static let shared = DownloadManager()
    
    // Maps download object to its associated info
    private var activeDownloads = [WKDownload: (windowID: ID<WindowState>, downloadID: ID<Download>)]()
    
    // Maps download IDs to the last time progress was updated
    private var lastProgressUpdateTime = [ID<Download>: Date]()
    
    // Minimum time between progress updates (0.5 seconds)
    private let progressUpdateThreshold: TimeInterval = 0.5
    
    // Create the standard downloads directory path
    private let downloadsDirectory: URL = {
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }()
    
    private override init() {
        super.init()
    }
    
    // Handle download from navigation action
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload, windowID: ID<WindowState>) {
        setupDownload(download, windowID: windowID)
    }
    
    // Handle download from navigation response
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload, windowID: ID<WindowState>) {
        setupDownload(download, windowID: windowID)
    }
    
    private func setupDownload(_ download: WKDownload, windowID: ID<WindowState>) {
        download.delegate = self
        
        // Create unique ID for this download
        let downloadID = ID<Download>.assign()
        
        // Store the download association
        activeDownloads[download] = (windowID: windowID, downloadID: downloadID)
        
        // Check if sidebar is locked and show toast if it's not
        if let window = BrowserStore.shared.model.windows[windowID], !window.sidebarLocked {
            // Create a toast notification for the download start
            let toast = Toast(
                message: "Download started",
                icon: "arrow.down.circle",
                location: .nearSidebar
            )
            
            // Add toast to window state
            BrowserStore.shared.modify { state in
                state.windows[windowID]?.toasts.append(toast)
            }
        }
    }
    
    // MARK: - WKDownloadDelegate
    
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let (windowID, downloadID) = activeDownloads[download] else {
            completionHandler(nil)
            return
        }
        
        // Create unique destination URL in ~/Downloads directory
        let destinationURL = URL.unique(folder: downloadsDirectory, name: suggestedFilename)
        
        // Create and add the download to browser state
        let newDownload = Download(
            id: downloadID,
            url: response.url ?? URL(string: "about:blank")!,
            destinationURL: destinationURL,
            suggestedFilename: suggestedFilename
        )
        
        BrowserStore.shared.modify { state in
            // Add the download to the window's state
            state.windows[windowID]?.downloads[downloadID] = newDownload
        }
        
        completionHandler(destinationURL)
        // TODO: Can we read from disk
    }
    
//    public func download(_ download: WKDownload, didReceive response: URLResponse) {
//        guard let (windowID, downloadID) = activeDownloads[download] else { return }
//        
//        BrowserStore.shared.modify { state in
//            guard let window = state.windows[windowID],
//                  var downloadInfo = window.downloads[downloadID] else { return }
//            
//            // Update estimated size
//            downloadInfo.estimatedSize = response.expectedContentLength
//            state.windows[windowID]?.downloads[downloadID] = downloadInfo
//        }
//    }
//    
//    public func download(_ download: WKDownload, didReceiveData totalBytesReceived: Int64, totalBytesExpected: Int64) {
//        guard let (windowID, downloadID) = activeDownloads[download] else { return }
//        
//        let now = Date()
//        let lastUpdate = lastProgressUpdateTime[downloadID] ?? Date(timeIntervalSince1970: 0)
//        let timeElapsed = now.timeIntervalSince(lastUpdate)
//        let progress = totalBytesExpected > 0 ? Double(totalBytesReceived) / Double(totalBytesExpected) : 0
//        
//        // Only update the progress if enough time has elapsed or if it's the first update or if progress is 100%
//        if timeElapsed >= progressUpdateThreshold || lastUpdate.timeIntervalSince1970 == 0 || progress >= 1.0 {
//            lastProgressUpdateTime[downloadID] = now
//            
//            BrowserStore.shared.modify { state in
//                guard let window = state.windows[windowID],
//                      var downloadInfo = window.downloads[downloadID] else { return }
//                
//                // Update progress and size info
//                downloadInfo.progress = progress
//                downloadInfo.currentSize = totalBytesReceived
//                downloadInfo.estimatedSize = totalBytesExpected
//                
//                state.windows[windowID]?.downloads[downloadID] = downloadInfo
//            }
//        }
//    }
    
    public func downloadDidFinish(_ download: WKDownload) {
        guard let (windowID, downloadID) = activeDownloads[download] else { return }
        
        BrowserStore.shared.modify { state in
            guard let window = state.windows[windowID],
                  var downloadInfo = window.downloads[downloadID] else { return }
            
            // Mark download as completed
            downloadInfo.status = .completed
            downloadInfo.progress = 1.0
            
            // Get actual file size from disk
            do {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: downloadInfo.destinationURL.path)
                if let fileSize = fileAttributes[.size] as? NSNumber {
                    downloadInfo.currentSize = fileSize.int64Value
                    downloadInfo.estimatedSize = fileSize.int64Value
                }
            } catch {
                print("Error reading file size: \(error)")
            }
            
            state.windows[windowID]?.downloads[downloadID] = downloadInfo
        }
        
        // Clean up
        if let (_, downloadID) = activeDownloads[download] {
            lastProgressUpdateTime.removeValue(forKey: downloadID)
        }
        activeDownloads.removeValue(forKey: download)
    }
    
    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let (windowID, downloadID) = activeDownloads[download] else { return }
        
        BrowserStore.shared.modify { state in
            guard let window = state.windows[windowID],
                  var downloadInfo = window.downloads[downloadID] else { return }
            
            // Mark download as failed
            downloadInfo.status = .failed
            downloadInfo.error = error.localizedDescription
            
            state.windows[windowID]?.downloads[downloadID] = downloadInfo
        }
        
        // Clean up
        if let (_, downloadID) = activeDownloads[download] {
            lastProgressUpdateTime.removeValue(forKey: downloadID)
        }
        activeDownloads.removeValue(forKey: download)
    }
    
    // Cancel a download
    public func cancelDownload(id: ID<Download>, windowID: ID<WindowState>) {
        // Find the WKDownload associated with this downloadID
        if let (download, _) = activeDownloads.first(where: { $0.value.downloadID == id }) {
            download.cancel()
            
            BrowserStore.shared.modify { state in
                guard let window = state.windows[windowID],
                      var downloadInfo = window.downloads[id] else { return }
                
                // Mark download as cancelled
                downloadInfo.status = .cancelled
                
                state.windows[windowID]?.downloads[id] = downloadInfo
            }
            
            // Clean up
            lastProgressUpdateTime.removeValue(forKey: id)
            activeDownloads.removeValue(forKey: download)
        } else {
            // Already completed or failed, just update the state
            BrowserStore.shared.modify { state in
                guard let window = state.windows[windowID],
                      var downloadInfo = window.downloads[id] else { return }
                
                // Update status only if it was in progress
                if downloadInfo.status == .inProgress {
                    downloadInfo.status = .cancelled
                    state.windows[windowID]?.downloads[id] = downloadInfo
                }
            }
        }
    }
    
    // Remove a download from the list
    public func removeDownload(id: ID<Download>, windowID: ID<WindowState>) {
        // If download is in progress, cancel it first
        if activeDownloads.values.contains(where: { $0.downloadID == id }) {
            cancelDownload(id: id, windowID: windowID)
        }
        
        // Remove from the state and cleanup
        lastProgressUpdateTime.removeValue(forKey: id)
        
        BrowserStore.shared.modify { state in
            state.windows[windowID]?.downloads.removeValue(forKey: id)
        }
    }
    
    // Delete the downloaded file from disk
    public func deleteDownloadedFile(id: ID<Download>, windowID: ID<WindowState>) {
        if let window = BrowserStore.shared.model.windows[windowID], 
           let download = window.downloads[id] {
            
            if download.status == .completed {
                do {
                    try FileManager.default.removeItem(at: download.destinationURL)
                } catch {
                    print("Error deleting file: \(error)")
                }
            }
            
            // Then remove the download from the list
            removeDownload(id: id, windowID: windowID)
        }
    }
    
    // Open the downloaded file
    public func openDownloadedFile(id: ID<Download>, windowID: ID<WindowState>) {
        if let window = BrowserStore.shared.model.windows[windowID], 
           let download = window.downloads[id], 
           download.status == .completed {
            
            #if os(macOS)
            NSWorkspace.shared.open(download.destinationURL)
            #endif
        }
    }
}
