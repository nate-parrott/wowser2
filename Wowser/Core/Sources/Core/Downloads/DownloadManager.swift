import Foundation
import WebKit
import Combine

/// A download's status record. Lives on the file-browser `Pane` that was
/// opened to show the download (`Pane.download`); the pane's URL points at
/// `destinationURL`.
public struct Download: Codable, Equatable {
    public var url: URL
    public var destinationURL: URL
    public var suggestedFilename: String
    public var startDate: Date
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

extension BrowserState {
    /// Opens a (background) file-browser tab pointed at the download's
    /// destination file, tagged with the download record. Returns the pane ID
    /// the record lives on.
    @discardableResult
    public mutating func openDownloadTab(_ download: Download, windowID: ID<WindowState>) -> ID<WebContent>? {
        let key = NativePageKey.fileBrowser(path: download.destinationURL.path)
        let tab = openTab(url: key.url, activate: false, windowID: windowID)
        guard let paneID = tab.panes.first?.id else { return nil }
        modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
            pane.download = download
        }
        return paneID
    }

    /// Asks the sidebar row for the tab containing `paneID` to pop.
    public mutating func popTab(containingPaneID paneID: ID<WebContent>) {
        if let tabID = paneToTabMapping[paneID] { popTab(id: tabID) }
    }

    public mutating func modifyDownload(paneID: ID<WebContent>, _ block: (inout Download) -> Void) {
        modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
            guard var d = pane.download else { return }
            block(&d)
            pane.download = d
        }
    }
}

public class DownloadManager: NSObject, WKDownloadDelegate {
    public static let shared = DownloadManager()

    private struct Active {
        var windowID: ID<WindowState>
        var paneID: ID<WebContent>?
        var progressObservation: NSKeyValueObservation?
        var lastProgressUpdate: Date = .distantPast
    }

    private var activeDownloads = [WKDownload: Active]()

    // Minimum time between progress writes into the store
    private let progressUpdateThreshold: TimeInterval = 0.3

    private let downloadsDirectory: URL = {
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }()

    private override init() {
        super.init()
    }

    /// True while WebKit is still actively downloading into this pane. Lets
    /// the UI tell "in progress" apart from "interrupted by a relaunch".
    public func isActive(paneID: ID<WebContent>) -> Bool {
        activeDownloads.values.contains(where: { $0.paneID == paneID })
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload, windowID: ID<WindowState>) {
        setupDownload(download, windowID: windowID)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload, windowID: ID<WindowState>) {
        setupDownload(download, windowID: windowID)
    }

    private func setupDownload(_ download: WKDownload, windowID: ID<WindowState>) {
        download.delegate = self
        activeDownloads[download] = Active(windowID: windowID)
    }

    // MARK: - WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let active = activeDownloads[download] else {
            completionHandler(nil)
            return
        }
        let destinationURL = URL.unique(folder: downloadsDirectory, name: suggestedFilename)
        let record = Download(
            url: response.url ?? URL(string: "about:blank")!,
            destinationURL: destinationURL,
            suggestedFilename: suggestedFilename,
            estimatedSize: response.expectedContentLength
        )

        var paneID: ID<WebContent>?
        BrowserStore.shared.modify { state in
            paneID = state.openDownloadTab(record, windowID: active.windowID)
        }
        activeDownloads[download]?.paneID = paneID
        // Pop the new tab on the next runloop turn so the row exists (and has
        // seen its initial count) before the change it animates on.
        if let paneID {
            DispatchQueue.main.async {
                BrowserStore.shared.modify { $0.popTab(containingPaneID: paneID) }
            }
        }

        // WKDownloadDelegate has no public per-chunk callback; observe the
        // download's Progress instead and throttle writes into the store.
        activeDownloads[download]?.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.progressDidChange(download, progress: progress)
            }
        }

        completionHandler(destinationURL)
    }

    private func progressDidChange(_ download: WKDownload, progress: Progress) {
        guard let active = activeDownloads[download], let paneID = active.paneID else { return }
        let now = Date()
        let fraction = progress.fractionCompleted
        if now.timeIntervalSince(active.lastProgressUpdate) < progressUpdateThreshold && fraction < 1.0 { return }
        activeDownloads[download]?.lastProgressUpdate = now
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        BrowserStore.shared.modify { state in
            state.modifyDownload(paneID: paneID) { d in
                guard d.status == .inProgress else { return }
                d.progress = fraction
                d.currentSize = completed
                if total > 0 { d.estimatedSize = total }
            }
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let active = activeDownloads[download] else { return }
        if let paneID = active.paneID {
            BrowserStore.shared.modify { state in
                state.modifyDownload(paneID: paneID) { d in
                    d.status = .completed
                    d.progress = 1.0
                    if let size = (try? FileManager.default.attributesOfItem(atPath: d.destinationURL.path)[.size] as? NSNumber)?.int64Value {
                        d.currentSize = size
                        d.estimatedSize = size
                    }
                }
            }
        }
        activeDownloads.removeValue(forKey: download)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let active = activeDownloads[download] else { return }
        if let paneID = active.paneID {
            BrowserStore.shared.modify { state in
                state.modifyDownload(paneID: paneID) { d in
                    d.status = .failed
                    d.error = error.localizedDescription
                }
            }
        }
        activeDownloads.removeValue(forKey: download)
    }

    // MARK: - Actions

    public func cancelDownload(paneID: ID<WebContent>) {
        if let (download, _) = activeDownloads.first(where: { $0.value.paneID == paneID }) {
            download.cancel()
            activeDownloads.removeValue(forKey: download)
        }
        BrowserStore.shared.modify { state in
            state.modifyDownload(paneID: paneID) { d in
                if d.status == .inProgress { d.status = .cancelled }
            }
        }
    }
}
