import Foundation

// User-created toolbar buttons (BrowserState+Toolbar.swift) lean on agents in
// three places, all run as agent tabs attached to the window's omnibox (see
// BrowserState+AttachedAgents) with the current page captured as context:
//
//   .author — right after the user creates a button: pick an icon and write
//             its BrowserJS (or leave it agent-backed if code can't do it).
//   .fix    — a button's BrowserJS threw on click.
//   .click  — an agent-backed button (bjs == nil) was clicked.

public struct ToolbarButtonJob: Equatable {
    public enum Kind: Equatable {
        case author
        case fix(error: String)
        case click(modifiers: [String])
    }
    public var button: CustomToolbarButton
    public var kind: Kind

    var isClick: Bool {
        if case .click = kind { return true }
        return false
    }

    /// Short name shown in the omnibox's "agent working" indicator.
    var title: String {
        switch kind {
        case .author: return "Building button: \(button.label)"
        case .fix: return "Fixing button: \(button.label)"
        case .click: return button.label
        }
    }
}

/// Which custom buttons currently have an agent writing or repairing their
/// code (transient; drives the "Coding this up…" subtitle in the customizer).
@MainActor
public final class ToolbarButtonAgentStatus: ObservableObject {
    public static let shared = ToolbarButtonAgentStatus()
    @Published public private(set) var working: Set<String> = []

    func setWorking(_ id: String, _ on: Bool) {
        if on { working.insert(id) } else { working.remove(id) }
    }
}

/// Runs a custom toolbar button on click: executes its BrowserJS, or hands
/// the click to an agent when it has none. A failing script gets a toast
/// and an agent to repair it.
@MainActor
public enum ToolbarButtonRunner {
    private static let runtime = BrowserJSRuntime(host: BrowserJSLiveHost.shared, helpers: BrowserJSHelpers.shared)

    public static func click(buttonID: String, webContentID: ID<WebContent>?, windowID: ID<WindowState>) {
        let state = BrowserStore.shared.model
        guard let button = state.toolbarConfig.customButton(id: buttonID) else { return }
        let modifiers = currentModifiers()

        guard let bjs = button.bjs, !bjs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AgentChatTabs.runToolbarButtonJob(ToolbarButtonJob(button: button, kind: .click(modifiers: modifiers)), windowID: windowID)
            return
        }

        var args: [String: Any] = ["buttonId": button.id, "windowId": windowID.raw, "modifiers": modifiers]
        if let webContentID {
            args["tabId"] = webContentID.raw
            if let url = state.pane(forId: webContentID)?.info.url { args["url"] = url.absoluteString }
        }
        let argsJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: args), let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()
        let code = "const args = \(argsJSON);\n" + bjs
        Task {
            let result = await runtime.run(code: code)
            if let error = result.error {
                BrowserStore.shared.modify { $0.addToast(message: "“\(button.label)” failed — asking an agent to fix it", icon: button.icon, in: windowID) }
                AgentChatTabs.runToolbarButtonJob(ToolbarButtonJob(button: button, kind: .fix(error: String(error.prefix(2000)))), windowID: windowID)
            }
        }
    }

    private static func currentModifiers() -> [String] {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var out: [String] = []
        if flags.contains(.shift) { out.append("shift") }
        if flags.contains(.option) { out.append("option") }
        if flags.contains(.command) { out.append("command") }
        if flags.contains(.control) { out.append("control") }
        return out
        #else
        return []
        #endif
    }
}

#if os(macOS)
import AppKit
#endif

extension AgentChatTabs {
    /// Spawns an agent for a toolbar-button job, attached to `windowID`'s
    /// omnibox, with the window's current page as context.
    public static func runToolbarButtonJob(_ job: ToolbarButtonJob, windowID: ID<WindowState>) {
        installToolsIfNeeded()
        let key = keyPrefix + "btn-" + String(UUID().uuidString.lowercased().prefix(8))
        let sourcePaneID = BrowserStore.shared.model.currentPane(forWindow: windowID)?.id
        let url = NativePageKey.agent(key: key, query: job.title).url
        let paneID = insertAttachedTab(key: key, url: url, windowID: windowID)
        if !job.isClick { ToolbarButtonAgentStatus.shared.setWorking(job.button.id, true) }
        AgentChatSession.session(forKey: key).begin(
            query: job.userMessage,
            ownPaneID: paneID,
            sourcePaneID: sourcePaneID,
            ownTabIsFocused: false,
            mode: .toolbarButton(job)
        )
    }
}

extension ToolbarButtonJob {
    /// The agent's first user message.
    var userMessage: String {
        let def = definitionText
        switch kind {
        case .author:
            return """
            The user just created a new toolbar button and it needs implementing.

            \(def)

            Implement it now (see the system prompt for how).
            """
        case .fix(let error):
            return """
            The user clicked their toolbar button and its BrowserJS threw:

            \(error)

            \(def)

            Fix the button's bjs (or, if this can't be done in code, make it agent-backed by setting bjs to null).
            """
        case .click(let modifiers):
            var s = "The user clicked their toolbar button “\(button.label)”"
            if !modifiers.isEmpty { s += " while holding \(modifiers.joined(separator: "+"))" }
            s += " on the page described in the system prompt. Do what the button is for."
            if let instructions = button.instructions, !instructions.isEmpty {
                s += "\n\nThe button's purpose, in the user's words:\n\"\"\"\n\(instructions)\n\"\"\""
            }
            return s
        }
    }

    private var definitionText: String {
        var s = "Button id: \"\(button.id)\"\nLabel: \(button.label)\nIcon: \(button.icon)"
        if let instructions = button.instructions, !instructions.isEmpty {
            s += "\nWhat the user said it should do:\n\"\"\"\n\(instructions)\n\"\"\""
        }
        if let bjs = button.bjs {
            s += "\nCurrent bjs:\n```js\n\(bjs)\n```"
        } else {
            s += "\nCurrent bjs: null (agent-backed)"
        }
        return s
    }

    /// Everything the agent needs to know about the toolbar button API and
    /// how to behave for this job. Appended to the page-context prompt.
    func systemPromptSection(agentURL: String, ownPaneID: String) -> String {
        let api = """
        ## Custom toolbar buttons

        The toolbar of every web tab has user-created buttons stored as \
        { id, label, icon, bjs, instructions }. `icon` is an SF Symbol name. \
        `bjs` is the BODY of an async BrowserJS function run on click with \
        `browser` in scope and `args = { buttonId, tabId, url, windowId, modifiers }` \
        (the tab the user clicked in, its URL, and held modifier keys like \
        ["shift"]). When `bjs` is null the button is "agent-backed": each \
        click spawns an agent like you with the page and click details — use \
        that for jobs that need judgment (summarize, decide, write prose), and \
        code for anything mechanical (open a URL, run page JS, toggle something).

        Edit buttons with `run_browser_js`:
          await browser.toolbar.get(id)
          await browser.toolbar.update(id, { icon, bjs, label })   // bjs: null → agent-backed
          await browser.toolbar.click(id, { tabId })               // test it as if clicked in that tab
        Call `get_browser_js_docs` for the full `browser.*` surface your bjs can use.
        Keep bjs short and robust; prefer `browser.tabs.*` / `browser.page.*` \
        over fragile page scripting. Test with `browser.toolbar.click` and fix \
        anything that throws.
        """
        switch kind {
        case .author:
            return api + """


            ## Your job: implement the new button

            1. Pick a fitting SF Symbol for `icon` (the current one is a placeholder).
            2. Write `bjs` that does what the user asked, using the page they're on as \
            the example target — or set `bjs: null` if the job needs judgment per click.
            3. Save with `browser.toolbar.update`, test with `browser.toolbar.click` \
            (args.tabId should be the user's current tab), and fix any errors.
            Work silently: do NOT focus your own tab. When done, call the `done` tool.
            """
        case .fix:
            return api + """


            ## Your job: repair the button

            Diagnose the error, update `bjs` with `browser.toolbar.update`, and \
            re-test with `browser.toolbar.click` in the user's tab. Work silently — \
            do NOT focus your own tab — and call the `done` tool when it works.
            """
        case .click:
            return api + """


            ## Your job: act on the click

            Your chat tab (id "\(ownPaneID)", url "\(agentURL)") is HIDDEN behind \
            the address bar. If the result is something to read (a summary, an \
            answer), show it in a split beside the user's page:
              await browser.tabs.openSplit("\(agentURL)", { besideTabId: args_tab, activate: true }); await browser.tabs.close("\(ownPaneID)");
            (replace args_tab with the user's tab id from the context above) and \
            write your answer here. If the click's job is an action (navigate, \
            change the page, save something), do it and then call the `done` tool \
            so your tab dismisses itself.
            """
        }
    }
}
