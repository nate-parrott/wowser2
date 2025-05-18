#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

#if os(iOS)
extension UIView {
    func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}
#endif

enum Alerts {
    // TODO: associate with the particular doc
    #if os(macOS)
    private static var windowForAlerts: NSWindow? {
        let allWindows: [NSWindow?] = [NSApplication.shared.keyWindow, NSApplication.shared.mainWindow] + NSApplication.shared.windows.reversed().asArray
        return allWindows.compactMap({ $0 }).first
    }
    #else
    private static func viewControllerForAlerts() -> UIViewController? {
        // Get the root view controller
        guard let rootVC = UIApplication.shared.windows.first?.rootViewController else {
            return nil
        }
        
        // Find the presented view controller (if any)
        var currentVC = rootVC
        while let presentedVC = currentVC.presentedViewController {
            currentVC = presentedVC
        }
        
        return currentVC
    }
    #endif

    @MainActor
    static func showAppAlert(title: String, message: String, baseView: UINSView? = nil) async {
        #if os(macOS)
        guard let mainWin = baseView?.window ?? windowForAlerts else { return }
        // Written by Phil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        _ = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                alert.beginSheetModal(for: mainWin) { response in
                    continuation.resume(returning: response)
                }
            }
        }
        #else
        guard let viewController = (baseView?.findViewController() ?? viewControllerForAlerts()) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                viewController.present(alert, animated: true) {
                    continuation.resume(returning: ())
                }
            }
        }
        #endif
    }

    @MainActor
    static func showAppConfirmationDialog(title: String, message: String, yesTitle: String, noTitle: String, baseView: UINSView? = nil) async -> Bool {
        #if os(macOS)
        // Written by Phil
        guard let mainWin = baseView?.window ?? windowForAlerts else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: yesTitle)
        alert.addButton(withTitle: noTitle)
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                alert.beginSheetModal(for: mainWin) { response in
                    let confirmed = (response == .alertFirstButtonReturn)
                    continuation.resume(returning: confirmed)
                }
            }
        }
        #else
        guard let viewController = (baseView?.findViewController() ?? viewControllerForAlerts()) else { return false }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        return await withCheckedContinuation { continuation in
            let yesAction = UIAlertAction(title: yesTitle, style: .default) { _ in
                continuation.resume(returning: true)
            }
            alert.addAction(yesAction)
            
            let noAction = UIAlertAction(title: noTitle, style: .cancel) { _ in
                continuation.resume(returning: false)
            }
            alert.addAction(noAction)
            
            DispatchQueue.main.async {
                viewController.present(alert, animated: true)
            }
        }
        #endif
    }

    @MainActor
    static func showAppPrompt(
        title: String,
        message: String,
        textPlaceholder: String,
        submitTitle: String,
        cancelTitle: String,
        baseView: UINSView? = nil
    ) async -> String? {
        #if os(macOS)
        guard let mainWin = baseView?.window ?? windowForAlerts else { return nil }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: submitTitle)
        alert.addButton(withTitle: cancelTitle)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = textPlaceholder
        alert.accessoryView = input

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                alert.beginSheetModal(for: mainWin) { response in
                    if response == .alertFirstButtonReturn {
                        continuation.resume(returning: input.stringValue)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        #else
        guard let viewController = (baseView?.findViewController() ?? viewControllerForAlerts()) else { return nil }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = textPlaceholder
        }
        
        return await withCheckedContinuation { continuation in
            let submitAction = UIAlertAction(title: submitTitle, style: .default) { _ in
                let text = alert.textFields?.first?.text
                continuation.resume(returning: text)
            }
            alert.addAction(submitAction)
            
            let cancelAction = UIAlertAction(title: cancelTitle, style: .cancel) { _ in
                continuation.resume(returning: nil)
            }
            alert.addAction(cancelAction)
            
            DispatchQueue.main.async {
                viewController.present(alert, animated: true)
            }
        }
        #endif
    }
}
