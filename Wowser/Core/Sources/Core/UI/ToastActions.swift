import Foundation

public extension ToastAction.Kind {
    /// Runs the action. Called by the toast UI when its button is tapped.
    func perform() {
        switch self {
        case .autofillForget(let profile, let ids):
            AutofillStore.shared.forget(ids: ids, profile: profile)
        case .autofillNeverRemember(let profile, let domain, let ids):
            AutofillStore.shared.neverRemember(domain: domain, forgetting: ids, profile: profile)
        case .agentReply(let target, let toast, let choice):
            Task { await AgentToastReply.deliver(to: target, toast: toast, choice: choice) }
        }
    }
}

/// Sends the user's answer to an agent toast (`browser.toast.show`) back to
/// the agent that posted it.
enum AgentToastReply {
    /// `choice` nil = the user closed the toast without picking an action.
    static func message(toast: String, choice: String?) -> String {
        if let choice {
            return "[Toast reply] The user clicked \"\(choice)\" on your toast \"\(toast)\"."
        }
        return "[Toast reply] The user dismissed your toast \"\(toast)\" without choosing an action."
    }

    static func deliver(to target: AgentToastReplyTarget, toast: String, choice: String?) async {
        let text = message(toast: toast, choice: choice)
        switch target {
        case .agent(let key):
            guard let id = await BrowserJSLiveHost.resolveAgentID(forKey: key) else { return }
            try? await BrowserAgentManager.shared.send(
                id: id,
                text: text,
                images: [],
                displayText: choice.map { "Clicked “\($0)”" } ?? "Dismissed toast",
                role: "user"
            )
        case .terminal(let pane):
            #if os(macOS)
            await typeIntoTerminal(pane: pane, text: text)
            #endif
        }
    }

    #if os(macOS)
    /// Types the reply into the terminal running the agent and presses Return.
    /// Return goes separately: TUIs like `claude` treat one fast burst as a
    /// paste and won't submit it. If the agent has exited and the shell is at
    /// its prompt, drop the reply rather than run it as a command.
    @MainActor
    private static func typeIntoTerminal(pane: ID<WebContent>, text: String) async {
        guard let session = try? BrowserJSLiveHost.terminalSession(forID: pane.raw),
              !session.shellIsAtPrompt else { return }
        session.write(text.replacingOccurrences(of: "\n", with: " "))
        try? await Task.sleep(for: .milliseconds(150))
        session.write("\r")
    }
    #endif
}
