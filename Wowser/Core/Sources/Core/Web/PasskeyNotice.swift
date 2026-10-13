import Foundation
import WebKit

/// We can't do passkeys (no WebAuthn entitlement), and sites that ask for one
/// just hang or fail silently. So: tell pages up front that no platform
/// authenticator is available (many then skip straight to passwords), and
/// when a page asks for a passkey anyway, toast "Passkeys aren't supported".
enum PasskeyNotice {
    static let handlerName = "wowserPasskey"

    /// Wraps `navigator.credentials.get/create`: a WebAuthn request (other than
    /// silent "conditional" autofill requests) pings native before going on to
    /// fail as it would have.
    static let userScript = """
    (() => {
        const creds = navigator.credentials;
        if (!creds || window.__wowserPasskeyShim) return;
        window.__wowserPasskeyShim = true;
        const notify = (kind) => {
            try { window.webkit.messageHandlers.\(handlerName).postMessage(kind); } catch (_) {}
        };
        for (const name of ['get', 'create']) {
            const original = creds[name];
            if (typeof original !== 'function') continue;
            creds[name] = function (options) {
                if (options && options.publicKey && options.mediation !== 'conditional') notify(name);
                return original.apply(creds, arguments);
            };
        }
        const PKC = window.PublicKeyCredential;
        if (PKC) {
            PKC.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
            PKC.isConditionalMediationAvailable = () => Promise.resolve(false);
        }
    })();
    """

    /// Pages we know are a passkey prompt (e.g. Google's "Use your passkey" step).
    static func isPasskeyChallenge(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        return host == "accounts.google.com" && url.path.contains("/challenge/pk")
    }

    private static var lastShown: [ID<WebContent>: Date] = [:]

    /// Toasts in the pane's window, at most once a minute per pane.
    static func show(forPane paneID: ID<WebContent>) {
        DispatchQueue.main.async {
            let now = Date()
            if let last = lastShown[paneID], now.timeIntervalSince(last) < 60 { return }
            lastShown[paneID] = now
            BrowserStore.shared.modify { state in
                guard let windowID = state.windowContaining(webContentId: paneID)?.id else { return }
                state.addToast(message: "Passkeys aren't supported in Wowser yet. Try another way to sign in.", icon: "person.badge.key", in: windowID)
            }
        }
    }

    /// Adds the user script (fresh configs only; inherited popup configs
    /// already carry it) and (re)points the message handler at `paneID`.
    static func install(on config: WKWebViewConfiguration, isFreshConfig: Bool, paneID: ID<WebContent>) {
        let ucc = config.userContentController
        if isFreshConfig {
            ucc.addUserScript(WKUserScript(source: userScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        } else {
            ucc.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        }
        ucc.add(PasskeyNoticeBridge(paneID: paneID), contentWorld: .page, name: handlerName)
    }
}

private final class PasskeyNoticeBridge: NSObject, WKScriptMessageHandler {
    let paneID: ID<WebContent>

    init(paneID: ID<WebContent>) { self.paneID = paneID }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        PasskeyNotice.show(forPane: paneID)
    }
}
