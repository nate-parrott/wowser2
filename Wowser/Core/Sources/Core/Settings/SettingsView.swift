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
    @AppStorage(DefaultsKeys.cleanModeForRecipes.rawValue) private var cleanModeForRecipesEnabled = false
    @AppStorage(DefaultsKeys.enableGoDirectQueries.rawValue) private var enableGoDirectQueries = true
    @AppStorage(DefaultsKeys.searchToolbarEnabled.rawValue) private var searchToolbarEnabled = false
    
    @AppStorage(DefaultsKeys.searchEngine.rawValue) private var searchEngine = SearchEngine.google.rawValue
    @AppStorage(DefaultsKeys.spaceThemeIntensity.rawValue) private var spaceThemeIntensity = 1.0
    
    public init() {
        
    }
    
    public var body: some View {
        Group {
            if #available(macOS 15.0, iOS 18.0, *) {
                TabView {
                    SwiftUI.Tab(content: { main }, label: { Text("General") })
                    SwiftUI.Tab(content: { AISettings() }, label: { Text("AI") })
                    SwiftUI.Tab(content: { MCPSettings() }, label: { Text("MCP") })
                    SwiftUI.Tab(content: { DebugSettings() }, label: { Text("Internal") })
                }
            } else {
                Color.red
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: isDesktop() ? 500 : nil)
    }
    
    @ViewBuilder private var main: some View {
        Form {
            Section("Tabs") {
                Toggle("Move old tabs to 'Old Tabs' every night", isOn: $autoArchiveTabsEnabled)
                    .help("When enabled, old tabs will be automatically archived and accessible via the Old Tabs menu")
                
                Toggle("Auto-organize tabs hourly", isOn: $autoOrganizeTabsEnabled)
                    .help("Automatically organize tabs into logical groups once per hour")
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
            
            Section("Appearance") {
//                Toggle("Top bar hidden unless hovered", isOn: $topbarLocked.not())
                Toggle("Dark mode on every site", isOn: $autoDarkModeEnabled)
                    .help("Automatically adjusts website appearance to match system dark mode when sites don't support it natively")

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
    
    var body: some View {
        Form {
            Section("AI Models") {
                EnumPicker<LLMChoice>(title: "AI Model", selection: $llmChoice) { model in
                    switch model {
                    case .openrouter_gpt_5_4_nano: return "OpenRouter - GPT-5.4 Nano"
                    case .openrouter_gemini_2_flash: return "OpenRouter - Gemini 2 Flash"
                    case .openrouter_gpt_4o: return "OpenRouter - GPT-4o"
                    case .openrouter_gpt_4o_mini: return "OpenRouter - GPT-4o Mini"
                    case .openrouter_llama_33_70b: return "OpenRouter - Llama 3.3 70B"
                    case .openrouter_haiku_35: return "OpenRouter - Claude 3.5 Haiku"
                    case .openrouter_custom: return "OpenRouter - Custom"
                        
                    case .openai_gpt_5_4_nano: return "OpenAI - GPT-5.4 Nano"
                    case .openai_gpt4o_mini: return "OpenAI - GPT-4o Mini"
                    case .openai_gpt4o: return "OpenAI - GPT-4o"
                    case .openai_custom: return "OpenAI - Custom"
                        
                    case .ollama_gemma_3_1b: return "Ollama - Gemma 3 1B"
                    case .ollama_gemma_3_4b: return "Ollama - Gemma 3 4B"
                    case .ollama_gemma_3_4b_qat: return "Ollama - Gemma 3 4B Quantized"
                    case .ollama_gemma_3_12b: return "Ollama - Gemma 3 12B"
                    case .ollama_custom: return "Ollama - Custom"
                        
                    case .anthropic_haiku_35: return "Anthropic - Claude 3.5 Haiku"
                    case .anthropic_custom: return "Anthropic - Custom"
                    }
                }
                
                showApiKeyFields()
                showCustomModelFields()
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

extension Binding where Value == Bool {
    func not() -> Binding<Bool> {
        .init(get: { !self.wrappedValue }, set: { self.wrappedValue = !$0 })
    }
}

struct DebugSettings: View {
    var body: some View {
        Form {
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
