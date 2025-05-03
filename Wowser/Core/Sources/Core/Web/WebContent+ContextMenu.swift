import WebKit
import Foundation
import AppKit

// MARK: - Context Menu
extension WebContent: WKUIDelegate {
    #if os(macOS)
    public func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (NSMenu?) -> Void) {
        let menu = NSMenu()
        
        // Get window ID
        guard let windowID = BrowserStore.shared.model.windowContaining(webContentId: id)?.id else {
            completionHandler(nil)
            return
        }
        
        // If it's a link, add "Download Link" option
        if let linkURL = elementInfo.linkURL {
            // Add standard "Open Link" option
            let openLinkItem = NSMenuItem(title: "Open Link", action: #selector(WebContentWebView.openLinkFromContextMenu(_:)), keyEquivalent: "")
            openLinkItem.representedObject = linkURL
            menu.addItem(openLinkItem)
            
            // Add "Open Link in New Tab" option
            let openLinkInNewTabItem = NSMenuItem(title: "Open Link in New Tab", action: #selector(WebContentWebView.openLinkInNewTabFromContextMenu(_:)), keyEquivalent: "")
            openLinkInNewTabItem.representedObject = linkURL
            menu.addItem(openLinkInNewTabItem)
            
            // Add separator
            menu.addItem(NSMenuItem.separator())
            
            // Add "Download Linked File" option
            let downloadLinkItem = NSMenuItem(title: "Download Linked File", action: #selector(WebContentWebView.downloadLinkFromContextMenu(_:)), keyEquivalent: "")
            downloadLinkItem.representedObject = ["url": linkURL, "windowID": windowID]
            menu.addItem(downloadLinkItem)
            
            // Add "Copy Link" option
            let copyLinkItem = NSMenuItem(title: "Copy Link", action: #selector(WebContentWebView.copyLinkFromContextMenu(_:)), keyEquivalent: "")
            copyLinkItem.representedObject = linkURL
            menu.addItem(copyLinkItem)
        }
        
        // If it's an image, add "Save Image" option
        if let imageURL = elementInfo.imageURL {
            // If we already have items in the menu, add a separator
            if menu.items.count > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            
            // Add "Save Image" option
            let saveImageItem = NSMenuItem(title: "Save Image", action: #selector(WebContentWebView.saveImageFromContextMenu(_:)), keyEquivalent: "")
            saveImageItem.representedObject = ["url": imageURL, "windowID": windowID]
            menu.addItem(saveImageItem)
            
            // Add "Copy Image" option
            let copyImageItem = NSMenuItem(title: "Copy Image", action: #selector(WebContentWebView.copyImageFromContextMenu(_:)), keyEquivalent: "")
            copyImageItem.representedObject = imageURL
            menu.addItem(copyImageItem)
        }
        
        // If menu is empty, return nil to use default menu
        if menu.items.isEmpty {
            completionHandler(nil)
            return
        }
        
        completionHandler(menu)
    }
    #endif
}

// MARK: - Context Menu Actions
extension WebContentWebView {
    @objc func openLinkFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        load(URLRequest(url: url))
    }
    
    @objc func openLinkInNewTabFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        
        // Creating a new window that will spawn a new tab
        let configuration = WKWebViewConfiguration()
        let request = URLRequest(url: url)
        
        // Use the WKUIDelegate to handle this new window/tab creation
        _ = self.createWebView(with: configuration, for: .init(request: request, initiatedByFrame: .init(request: request)), windowFeatures: WKWindowFeatures())
    }
    
    @objc func downloadLinkFromContextMenu(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let url = dict["url"] as? URL,
              let windowID = dict["windowID"] as? ID<WindowState> else { return }
        
        // Create a download request
        let request = URLRequest(url: url)
        
        // Start the download
        downloadUsingRequest(request, windowID: windowID)
    }
    
    @objc func copyLinkFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    
    @objc func saveImageFromContextMenu(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let url = dict["url"] as? URL,
              let windowID = dict["windowID"] as? ID<WindowState> else { return }
        
        // Create a download request
        let request = URLRequest(url: url)
        
        // Start the download
        downloadUsingRequest(request, windowID: windowID)
    }
    
    @objc func copyImageFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        
        // Fetch the image data asynchronously
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil,
                  let image = NSImage(data: data) else { return }
            
            // Copy the image to the pasteboard on the main thread
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            }
        }
        
        task.resume()
    }
}