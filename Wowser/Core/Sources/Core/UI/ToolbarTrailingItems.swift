import SwiftUI

/// Built-in buttons on the toolbar's trailing edge. Their order/visibility
/// (and user-created buttons alongside them) live in `BrowserState.toolbar`;
/// see BrowserState+Toolbar.swift and ToolbarTrailingRegion.swift.
public enum ToolbarTrailingItem: String, CaseIterable, Codable {
    case dictation
    case cleanMode
    case mobileViewport
    case bookmark
    case openChat
    case closePane
    case newSplitPane

    public var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .cleanMode: return "Clean Mode"
        case .mobileViewport: return "Mobile Viewport"
        case .bookmark: return "Bookmark"
        case .closePane: return "Close Pane"
        case .newSplitPane: return "New Split Pane"
        case .openChat: return "Open Chat in Split"
        }
    }

    /// Representative glyph for the customizer list (some buttons swap icons
    /// with state, e.g. bookmark filled/unfilled).
    public var icon: String {
        switch self {
        case .dictation: return "mic"
        case .cleanMode: return "book"
        case .mobileViewport: return "iphone.gen3"
        case .bookmark: return "bookmark"
        case .closePane: return "xmark"
        case .newSplitPane: return "plus"
        case .openChat: return "bubble.left"
        }
    }

    /// When the button is *eligible* to appear (it can still be hidden).
    public var availabilityNote: String? {
        switch self {
        case .dictation, .cleanMode, .bookmark: return nil
        case .mobileViewport: return "Only in dev mode"
        case .openChat: return "Only on pages without a chat"
        case .closePane: return "Only in split view"
        case .newSplitPane: return "Only on the last pane"
        }
    }
}

// MARK: - Opening Settings from Core

/// Tabs in the Settings window that can be targeted from elsewhere in the app.
public enum SettingsTab: String, Hashable, CaseIterable {
    case general, profiles, autofill, ai, tasks, memory, mcp, experimental

    public var title: String {
        switch self {
        case .general: return "General"
        case .profiles: return "Profiles"
        case .autofill: return "Autofill"
        case .ai: return "AI"
        case .tasks: return "Tasks"
        case .memory: return "Memory"
        case .mcp: return "MCP"
        case .experimental: return "Experimental"
//        case .debug: return "Internal"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .profiles: return "person.2"
        case .autofill: return "person.text.rectangle"
        case .ai: return "sparkles"
        case .tasks: return "checklist"
        case .memory: return "brain"
        case .mcp: return "server.rack"
        case .experimental: return "flask"
//        case .debug: return "wrench.and.screwdriver"
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
