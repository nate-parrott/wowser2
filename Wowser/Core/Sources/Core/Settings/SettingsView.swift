import SwiftUI

public struct SettingsView: View {
    @AppStorage(DefaultsKeys.adblock.rawValue) private var adblockEnabled = false
    @AppStorage(DefaultsKeys.cookieBannerBlock.rawValue) private var cookieBannerBlockEnabled = false
    @AppStorage(DefaultsKeys.autoDarkMode.rawValue) private var autoDarkModeEnabled = false
//    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @AppStorage(DefaultsKeys.animateNewTabs.rawValue) private var animateNewTabsEnabled = true
    @AppStorage(DefaultsKeys.preserveWindowsAcrossRestarts.rawValue) private var preserveWindowsAcrossRestarts = true
    @AppStorage(DefaultsKeys.autoOrganizeTabs.rawValue) private var autoOrganizeTabsEnabled = false
    @AppStorage(DefaultsKeys.autoArchiveTabs.rawValue) private var autoArchiveTabsEnabled = false
    @AppStorage(DefaultsKeys.cleanupTabs.rawValue) private var cleanupTabsEnabled = true
    @AppStorage(DefaultsKeys.sortExternalLinksIntoSpaces.rawValue) private var sortExternalLinksIntoSpaces = true
    @AppStorage(DefaultsKeys.allWindowsShareTabs.rawValue) private var allWindowsShareTabs = true
    @AppStorage(DefaultsKeys.cleanModeForRecipes.rawValue) private var cleanModeForRecipesEnabled = false
    @AppStorage(DefaultsKeys.enableGoDirectQueries.rawValue) private var enableGoDirectQueries = false
    @AppStorage(DefaultsKeys.searchToolbarEnabled.rawValue) private var searchToolbarEnabled = false
    @AppStorage(DefaultsKeys.chromiumEngine.rawValue) private var chromiumEngineEnabled = false
    @AppStorage(DefaultsKeys.dictationCleanup.rawValue) private var dictationCleanupEnabled = false
    @AppStorage(DefaultsKeys.dictationHotkey.rawValue) private var dictationHotkey = DictationHotkey.default.rawValue
    @AppStorage(DefaultsKeys.hideSiriAIOnTextSelection.rawValue) private var hideSiriAIOnTextSelection = true
    
    @AppStorage(DefaultsKeys.searchEngine.rawValue) private var searchEngine = SearchEngine.google.rawValue
    @AppStorage(DefaultsKeys.spaceThemeIntensity.rawValue) private var spaceThemeIntensity = 1.0
    
    @State private var selectedTab: SettingsTab

    public init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }
    
    public var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail(for: selectedTab)
                .navigationTitle(selectedTab.title)
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { note in
            if let tab = SettingsTab.from(note) { selectedTab = tab }
        }
        .formStyle(.grouped)
        .frame(minWidth: isDesktop() ? 640 : nil, minHeight: isDesktop() ? 400 : nil)
    }

    @ViewBuilder private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: main
        case .profiles: ProfilesSettings()
        case .autofill: AutofillSettingsView()
        case .ai: AISettings()
        case .tasks: TasksSettings()
        case .memory: MemorySettings()
        case .mcp: MCPSettings()
        case .experimental: ExperimentalSettings()
        case .credits: CreditsSettings()
//        case .debug: DebugSettings()
        }
    }
    
    @ViewBuilder private var main: some View {
        Form {
            Section("Tabs") {
                Toggle("All windows share tabs", isOn: $allWindowsShareTabs)
                    .help("Every window lists the space's tabs from all windows. Selecting a tab that's open in another window moves it to this one")

                Toggle("Move old tabs to 'Old Tabs' every night", isOn: $autoArchiveTabsEnabled)
                    .help("When enabled, old tabs will be automatically archived and accessible via the Old Tabs menu")
                
                Toggle("Auto-organize tabs hourly", isOn: $autoOrganizeTabsEnabled)
                    .help("Automatically organize tabs into logical groups once per hour")

                Toggle("Clean up stale tabs", isOn: $cleanupTabsEnabled)
                    .help("On launch and whenever tabs are organized, close old empty tabs, duplicates, Zoom/Meet leftovers, idle terminals, and agent-opened tabs you never viewed")

                Toggle("Sort links from other apps into the best space", isOn: $sortExternalLinksIntoSpaces)
                    .help("When another app opens a link, AI picks the space it fits best (based on space names and recently visited sites) and moves the tab there. Does nothing when you have only one space")
            }
            Section("Clean Mode") {
                Toggle("Hide ads", isOn: $adblockEnabled)
                Toggle("Hide cookie banners", isOn: $cookieBannerBlockEnabled)
                Toggle("Clean mode for recipes", isOn: $cleanModeForRecipesEnabled)
            }
            Section("Browsing") {
                EnumPicker<SearchEngine>(title: "Search Engine", selection: $searchEngine) { engine in
                    switch engine {
                    case .google: return "Google"
                    case .duckduckgo: return "DuckDuckGo"
                    case .kagi: return "Kagi"
                    case .clean: return "Clean Search"
                    case .images: return "Clean Image Search"
                    }
                }
                
                Toggle("Enable 'go direct' for navigational queries", isOn: $enableGoDirectQueries)
                    .help("When enabled, queries that appear to be navigational will show an 'I'm feeling lucky' result that takes you directly to the first search result")
                
                Toggle("Show search toolbar on search pages", isOn: $searchToolbarEnabled)
                    .help("Shows a toolbar with search options when viewing search results")
                                
                Toggle("Animate new tabs", isOn: $animateNewTabsEnabled)
                    .help("Show animation when new tabs are loaded")
                
                Toggle("Save windows when quitting", isOn: $preserveWindowsAcrossRestarts)
            }

            Section("Browser Engine") {
                Toggle("Use Chromium engine for new tabs", isOn: $chromiumEngineEnabled)
                    .disabled(!ChromiumSupport.isAvailable)
                    .help(ChromiumSupport.isAvailable
                          ? "New tabs render with Chromium (CEF) instead of WebKit. Existing tabs keep their engine."
                          : "This build doesn't include Chromium. Enable it with `touch Wowser/Core/.cef-enabled` and rebuild (see scripts/cef/README.md).")
                if !ChromiumSupport.isAvailable {
                    Text("Chromium is not included in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Dictation") {
                #if os(macOS)
                Picker("Push-to-talk shortcut", selection: $dictationHotkey) {
                    ForEach(DictationHotkey.allCases) { hotkey in
                        Text(hotkey.title).tag(hotkey.rawValue)
                    }
                }
                .help("Hold to dictate; release to finish. ⌘⌥ must be held alone for a second. ⌘D still toggles dictation.")
                #endif
                Toggle("Clean up dictated text with AI", isOn: $dictationCleanupEnabled)
                    .help("When dictating into a text field on a page (⌘D), send the transcript through the configured AI model to remove filler words and fix obvious transcription mistakes before inserting it. Dictation to the agent is never cleaned up — the agent is told it was dictated instead.")
            }

            Section("Appearance") {
//                Toggle("Top bar hidden unless hovered", isOn: $topbarLocked.not())
                Toggle("Dark mode on every site", isOn: $autoDarkModeEnabled)
                    .help("Automatically adjusts website appearance to match system dark mode when sites don't support it natively")
                Toggle("Hide Siri AI on text selection", isOn: $hideSiriAIOnTextSelection)
                    .help("Disables Writing Tools and the floating Siri button that appears when selecting text in pages. Takes effect for newly opened tabs.")

                Slider(value: $spaceThemeIntensity, in: 0...2) {
                    Text("Space color intensity")
                } minimumValueLabel: {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Vivid").font(.caption).foregroundStyle(.secondary)
                }
                .help("How strongly each space's auto-generated color scheme washes over the window background")
            }
        }
    }
}

struct ExperimentalSettings: View {
    @AppStorage(DefaultsKeys.autofillSearchableSelects.rawValue) private var searchableSelects = false

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Searchable dropdown menus", isOn: $searchableSelects)
                    .help("Replaces the native <select> popup on pages with a menu you can type into to filter options.")
            }

            #if os(macOS)
            Section {
                NetworkProxyKillSwitchSection()
            }

            Section {
                HTTPSCaptureSettingsSection()
            }
            #endif

            Section("Debug") {
                Button(action: { BrowserStore.shared.model.clearAllAITags() }) {
                    Text("Clear AI tags")
                }
            }
            
            Section("Advanced") {
                Button(action: { CleanModeStore.shared.resetToDefault() }) {
                    Text("Reset clean mode store")
                }
                .help("Resets all clean mode settings to default values")
            }
        }
    }
}

struct ProfilesSettings: View {
    var body: some View {
        // Must put form WITHIN WithSnapshotMain; cannot put WithSnapshotMain within Form
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { ProfilesSettingsSnapshot(state: $0) }) { snapshot in
            Form {
                Section {
                    Button("New Profile…") { BrowserStore.shared.showNewProfilePage() }
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Profiles grouped together share logins, passwords and autofill. Hidden profiles keep their tabs but don't appear in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.loginGroups, id: \.first?.id.raw) { group in
                    Section(group.count > 1 ? "Shared logins" : "") {
                        ForEach(group, id: \.id.raw) { entry in
                            ProfileSettingsRow(entry: entry)
                        }
                    }
                }
                #if os(macOS)
                ImportSettingsSection()
                #endif
            }
        }
    }
}

private struct ProfilesSettingsSnapshot: Equatable {
    struct Entry: Equatable {
        var id: ID<Profile>
        var displayName: String
        var visible: Bool
        /// False for the last visible profile: we never hide down to zero.
        var canToggle: Bool
    }
    /// See `BrowserState.allLoginGroups`.
    var loginGroups: [[Entry]]

    init(state: BrowserState) {
        loginGroups = state.allLoginGroups.map { group in
            group.map { profile in
                Entry(
                    id: profile.id,
                    displayName: (profile.emoji?.nilIfEmpty.map { "\($0) " } ?? "") + profile.displayName,
                    visible: !profile.isHidden,
                    canToggle: profile.isHidden || state.canHideProfile(profile.id)
                )
            }
        }
    }
}

private struct ProfileSettingsRow: View {
    var entry: ProfilesSettingsSnapshot.Entry

    var body: some View {
        HStack {
            Text(entry.displayName)
                .foregroundStyle(entry.visible ? .primary : .secondary)
            Spacer()
            Toggle("Visible", isOn: Binding(get: { entry.visible }, set: { setVisible($0) }))
                .fixedSize()
                .disabled(!entry.canToggle)
                .help(entry.canToggle ? "Show this profile in the sidebar" : "At least one profile must stay visible")
        }
    }

    private func setVisible(_ visible: Bool) {
        BrowserStore.shared.modify { state in
            if visible {
                state.unhideProfile(entry.id)
            } else {
                state.hideProfile(entry.id)
            }
        }
    }
}

struct EnumPicker<E: CaseIterable & Hashable & RawRepresentable>: View where E.RawValue == String {
    var title: String
    @Binding var selection: String
    var displayName: (E) -> String
    
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(E.allCases as! [E], id: \.self) { enumCase in
                Text(displayName(enumCase)).tag(enumCase.rawValue)
            }
        }
    }
}

struct AISettings: View {
    @AppStorage(DefaultsKeys.llmChoice.rawValue) private var llmChoice = LLMChoice.openai_gpt_5_4_nano.rawValue
    @AppStorage(DefaultsKeys.openrouterKey.rawValue) private var openrouterKey = ""
    @AppStorage(DefaultsKeys.openAIKey.rawValue) private var openAIKey = ""
    @AppStorage(DefaultsKeys.anthropicKey.rawValue) private var anthropicKey = ""
    @AppStorage(DefaultsKeys.ollamaCustomModel.rawValue) private var ollamaCustomModel = ""
    @AppStorage(DefaultsKeys.openrouterCustomModel.rawValue) private var openrouterCustomModel = ""
    @AppStorage(DefaultsKeys.openAICustomModel.rawValue) private var openAICustomModel = ""
    @AppStorage(DefaultsKeys.anthropicCustomModel.rawValue) private var anthropicCustomModel = ""
    @AppStorage(DefaultsKeys.agentShellTools.rawValue) private var agentShellTools = false
    @AppStorage(DefaultsKeys.agentHarness.rawValue) private var agentHarness = AgentHarness.claude.rawValue
    @AppStorage(DefaultsKeys.microAIBackends.rawValue) private var microAIBackends = ""
    @ObservedObject private var requestLog = AIRequestLog.shared

    var body: some View {
        let _ = microAIBackends
        Form {
            MicroAIFeaturesSection()

            if MicroAIFeaturesSection.anyFeatureUses(.openRouter) {
                Section("OpenRouter") {
                    EnumPicker<LLMChoice>(title: "AI Model", selection: $llmChoice) { $0.displayName }

                    showApiKeyFields()
                    showCustomModelFields()
                }
            }

            if MicroAIFeaturesSection.anyFeatureUses(.agent) {
                Section("Agent") {
                    Text("Each request starts a Claude Code session (\(MicroAI.agentModel), low effort) in a hidden working directory. Slower than the other options; needs the claude CLI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Agents") {
                Picker(selection: $agentHarness) {
                    ForEach(AgentHarness.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text("Chat agent")
                    Text("On device is private and free, but only answers questions, reads pages, and opens links. Applies to new chats.")
                }
                if agentHarness == AgentHarness.local.rawValue, !MicroAI.onDeviceAvailable {
                    Text("The on-device model isn't available. Turn on Apple Intelligence in System Settings to use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Give agents shell & file access", isOn: $agentShellTools)
                Text("Claude Code agents get Bash, Read, Write, Edit, Glob and Grep, with no permission prompts. Applies to newly started agents.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Last Request") {
                if let request = requestLog.lastRequest {
                    LastAIRequestDetails(request: request)
                } else {
                    Text("No AI requests yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private func showApiKeyFields() -> some View {
        Group {
            if llmChoice.hasPrefix("openrouter_") {
                SecureField("OpenRouter API Key", text: $openrouterKey)
            }
            
            if llmChoice.hasPrefix("openai_") {
                SecureField("OpenAI API Key", text: $openAIKey)
            }
            
            if llmChoice.hasPrefix("anthropic_") {
                SecureField("Anthropic API Key", text: $anthropicKey)
            }
        }
    }
    
    @ViewBuilder
    private func showCustomModelFields() -> some View {
        Group {
            if llmChoice == LLMChoice.openrouter_custom.rawValue {
                TextField("OpenRouter Custom Model", text: $openrouterCustomModel)
                    .help("Full model name (e.g. 'openai/gpt-4o-mini')")
            }
            
            if llmChoice == LLMChoice.openai_custom.rawValue {
                TextField("OpenAI Custom Model", text: $openAICustomModel)
                    .help("Model name (e.g. 'gpt-4o-mini')")
            }
            
            if llmChoice == LLMChoice.ollama_custom.rawValue {
                TextField("Ollama Custom Model", text: $ollamaCustomModel)
                    .help("Model name (e.g. 'llama3:8b')")
            }
            
            if llmChoice == LLMChoice.anthropic_custom.rawValue {
                TextField("Anthropic Custom Model", text: $anthropicCustomModel)
                    .help("Model name (e.g. 'claude-3-haiku-20240307')")
            }
        }
    }
}

private struct LastAIRequestDetails: View {
    var request: AIRequestRecord

    var body: some View {
        LabeledContent("Status", value: statusText)
        LabeledContent("Model", value: request.modelName)
        LabeledContent("Time", value: request.date.formatted(date: .abbreviated, time: .standard))
        if let duration = request.durationSeconds {
            LabeledContent("Duration", value: String(format: "%.1fs", duration))
        }
        if let promptTokens = request.promptTokens, let completionTokens = request.completionTokens {
            LabeledContent("Tokens", value: tokensText(promptTokens: promptTokens, completionTokens: completionTokens))
        }
        if let cost = request.cost {
            LabeledContent("Cost", value: String(format: "$%.5f", cost))
        }
        if let error = request.errorDescription {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var statusText: String {
        switch request.status {
        case .inFlight: return "In progress…"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        }
    }

    private func tokensText(promptTokens: Int, completionTokens: Int) -> String {
        var text = "\(promptTokens.formatted()) in, \(completionTokens.formatted()) out"
        if let cached = request.cachedPromptTokens, cached > 0 {
            text += " (\(cached.formatted()) cached)"
        }
        return text
    }
}

extension Binding where Value == Bool {
    func not() -> Binding<Bool> {
        .init(get: { !self.wrappedValue }, set: { self.wrappedValue = !$0 })
    }
}
