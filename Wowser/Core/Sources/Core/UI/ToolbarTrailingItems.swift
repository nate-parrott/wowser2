import SwiftUI

/// Buttons on the toolbar's trailing edge that the user can hide via right-click
/// or Settings → Toolbar. Persisted in `DefaultsKeys.hiddenTrailingToolbarItems`.
enum ToolbarTrailingItem: String, CaseIterable {
    case cleanMode
    case extensions
    case mobileViewport
    case bookmark
    case closePane
    case newSplitPane
    case openChat

    var title: String {
        switch self {
        case .cleanMode: return "Clean Mode"
        case .extensions: return "Extensions"
        case .mobileViewport: return "Mobile Viewport (Dev Mode)"
        case .bookmark: return "Bookmark"
        case .closePane: return "Close Pane"
        case .newSplitPane: return "New Split Pane"
        case .openChat: return "Open Chat in Split"
        }
    }

    var group: Group {
        switch self {
        case .cleanMode, .extensions, .mobileViewport, .bookmark, .openChat: return .page
        case .closePane, .newSplitPane: return .splitView
        }
    }

    enum Group: CaseIterable {
        case page
        case splitView

        var title: String {
            switch self {
            case .page: return "Page"
            case .splitView: return "Split View"
            }
        }

        var footer: String? {
            switch self {
            case .page: return nil
            case .splitView: return "Only shown when the window is split into multiple panes."
            }
        }

        var items: [ToolbarTrailingItem] { ToolbarTrailingItem.allCases.filter { $0.group == self } }
    }

    // MARK: Persistence (comma-separated raw values)

    static func hiddenItems(fromRaw raw: String) -> Set<ToolbarTrailingItem> {
        Set(raw.split(separator: ",").compactMap { ToolbarTrailingItem(rawValue: String($0)) })
    }

    static func raw(fromHiddenItems set: Set<ToolbarTrailingItem>) -> String {
        allCases.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

/// Shared toggle list for the toolbar's customization context menu and Settings → Toolbar.
struct ToolbarTrailingItemToggles: View {
    var items: [ToolbarTrailingItem]
    @AppStorage(DefaultsKeys.hiddenTrailingToolbarItems.rawValue) private var hiddenRaw = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            Toggle(item.title, isOn: Binding(
                get: { !ToolbarTrailingItem.hiddenItems(fromRaw: hiddenRaw).contains(item) },
                set: { shown in
                    var set = ToolbarTrailingItem.hiddenItems(fromRaw: hiddenRaw)
                    if shown { set.remove(item) } else { set.insert(item) }
                    hiddenRaw = ToolbarTrailingItem.raw(fromHiddenItems: set)
                }
            ))
        }
    }
}

struct ToolbarSettings: View {
    @AppStorage(DefaultsKeys.dictationButton.rawValue) private var dictationButtonEnabled = false

    var body: some View {
        Form {
            ForEach(ToolbarTrailingItem.Group.allCases, id: \.self) { group in
                Section {
                    ToolbarTrailingItemToggles(items: group.items)
                } header: {
                    Text(group.title)
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
            }
            Section("Address Bar") {
                Toggle("Dictation button", isOn: $dictationButtonEnabled)
                    .help("Shows a microphone button next to the address bar. Dictation is still available via ⌘D when this is off.")
            }
        }
    }
}

// MARK: - Opening Settings from Core

/// Tabs in the Settings window that can be targeted from elsewhere in the app.
public enum SettingsTab: String, Hashable, CaseIterable {
    case general, toolbar, profiles, ai, tasks, mcp, experimental, debug

    public var title: String {
        switch self {
        case .general: return "General"
        case .toolbar: return "Toolbar"
        case .profiles: return "Profiles"
        case .ai: return "AI"
        case .tasks: return "Tasks"
        case .mcp: return "MCP"
        case .experimental: return "Experimental"
        case .debug: return "Internal"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .toolbar: return "menubar.rectangle"
        case .profiles: return "person.2"
        case .ai: return "sparkles"
        case .tasks: return "checklist"
        case .mcp: return "server.rack"
        case .experimental: return "flask"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

public extension Notification.Name {
    /// Posted (on main) to ask the app to open the Settings window. `userInfo[SettingsTab.userInfoKey]`
    /// may carry a `SettingsTab` to select.
    static let showSettings = Notification.Name("wowser.showSettings")
}

public extension SettingsTab {
    static let userInfoKey = "tab"

    /// Ask the host app to open Settings on this tab.
    func open() {
        NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: [SettingsTab.userInfoKey: self])
    }

    static func from(_ notification: Notification) -> SettingsTab? {
        notification.userInfo?[userInfoKey] as? SettingsTab
    }
}
