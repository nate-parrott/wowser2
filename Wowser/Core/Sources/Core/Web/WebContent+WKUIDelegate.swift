import WebKit

extension WebContentWebKit: WKUIDelegate {
    // MARK: - WKUIDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {

        if let delegate {
            switch delegate.webContent(self, decidePolicyFor: navigationAction) {
            case .cancel, .download:
                return nil
            case .allow: () // Fall thru and allow loading in same tab
            default: return nil // Deny for unknown
            }
        }
        
        let newWebContent = WebContentWebKit(id: .assign(), datastoreUUID: datastoreUUID, config: configuration)
        if let url = navigationAction.request.url {
            newWebContent.populateWithInitialURL(url)
        }
        
        #if os(macOS)
        let commandPressed = NSEvent.modifierFlags.contains(.command)
        #else
        let commandPressed = false
        #endif
        delegate?.webContent(self, didSpawnNewWebContent: newWebContent, shouldActivate: !commandPressed)
        
        return newWebContent.webview
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        Task {
            await Alerts.showAppAlert(title: frame.request.url?.host ?? "JavaScript", message: message, baseView: webview)
            completionHandler()
        }
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        Task {
            let result = await Alerts.showAppPrompt(
                title: frame.request.url?.host ?? "JavaScript",
                message: prompt,
                textPlaceholder: defaultText ?? "",
                submitTitle: "OK",
                cancelTitle: "Cancel",
                baseView: webview
            )
            completionHandler(result)
        }
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        return await Alerts.showAppConfirmationDialog(
            title: frame.request.url?.host ?? "JavaScript",
            message: message,
            yesTitle: "OK",
            noTitle: "Cancel",
            baseView: webview
        )
    }
    
    #if os(iOS)
    /// Long-pressing a link: our own short menu instead of WebKit's.
    public func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else { return completionHandler(nil) }
        let paneID = id
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    BrowserStore.shared.modify { state in
                        guard let windowID = state.windowContaining(webContentId: paneID)?.id else { return }
                        _ = state.openTab(url: url, activate: false, windowID: windowID)
                    }
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = url
                },
            ])
        })
    }
    #endif

    #if os(macOS)
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = parameters.allowsDirectories
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        
        guard let window = webview.window else { return nil }
        
        let response = await openPanel.beginSheetModal(for: window)
        return response == .OK ? openPanel.urls : nil
    }

    /// Private WKUIDelegate hook behind `window.outerWidth/outerHeight/screenX/screenY`.
    /// Without it WebKit reports all four as 0, which breaks sites that infer
    /// page zoom from `outerWidth / innerWidth`. Like Chrome, this is the whole
    /// window (sidebar, splits and all), in Cocoa screen coordinates.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func _webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(webView.window?.frame ?? CGRect(origin: .zero, size: webView.bounds.size))
    }
    #endif
    
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        Task {
            let mediaType = type == .microphone ? "microphone" : type == .camera ? "camera" : "camera and microphone"
            let confirmed = await Alerts.showAppConfirmationDialog(
                title: "Media Access Request",
                message: "Allow \(origin.host) to access your \(mediaType)?",
                yesTitle: "Allow",
                noTitle: "Deny",
                baseView: webview
            )
            decisionHandler(confirmed ? .grant : .deny)
        }
    }
}
