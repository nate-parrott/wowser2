import SwiftUI
import Core

struct SettingsView: View {
    @AppStorage(DefaultsKeys.adblock.rawValue) private var adblockEnabled = false
    @AppStorage(DefaultsKeys.autoDarkMode.rawValue) private var autoDarkModeEnabled = false
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    @AppStorage(DefaultsKeys.animateNewTabs.rawValue) private var animateNewTabsEnabled = true
    @AppStorage(DefaultsKeys.preserveWindowsAcrossRestarts.rawValue) private var preserveWindowsAcrossRestarts = true
    

    
    var body: some View {
        Form {
            Section("Interface") {
                Toggle("Top bar hidden unless hovered", isOn: $topbarLocked.not())
            }
            Section("Browsing") {
                Toggle("Block ads", isOn: $adblockEnabled)
                    .help("Blocks ads on websites using built-in filter lists")
                
                Toggle("Dark mode on every site", isOn: $autoDarkModeEnabled)
                    .help("Automatically adjusts website appearance to match system dark mode when sites don't support it natively")
                
                Toggle("Animate new tabs", isOn: $animateNewTabsEnabled)
                    .help("Show animation when new tabs are loaded")
                
                Toggle("Save windows when quitting", isOn: $preserveWindowsAcrossRestarts)
            }
            
            AISettings()
            
            DebugSettings()
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500)
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
    @AppStorage(DefaultsKeys.llmChoice.rawValue) private var llmChoice = LLMChoice.openrouter_gemini_2_flash.rawValue
    @AppStorage(DefaultsKeys.openrouterKey.rawValue) private var openrouterKey = ""
    @AppStorage(DefaultsKeys.openAIKey.rawValue) private var openAIKey = ""
    @AppStorage(DefaultsKeys.anthropicKey.rawValue) private var anthropicKey = ""
    @AppStorage(DefaultsKeys.ollamaCustomModel.rawValue) private var ollamaCustomModel = ""
    @AppStorage(DefaultsKeys.openrouterCustomModel.rawValue) private var openrouterCustomModel = ""
    @AppStorage(DefaultsKeys.openAICustomModel.rawValue) private var openAICustomModel = ""
    @AppStorage(DefaultsKeys.anthropicCustomModel.rawValue) private var anthropicCustomModel = ""
    
    var body: some View {
        Section("AI Models") {
            EnumPicker<LLMChoice>(title: "AI Model", selection: $llmChoice) { model in
                switch model {
                case .openrouter_gemini_2_flash: return "OpenRouter - Gemini 2 Flash"
                case .openrouter_gpt_4o: return "OpenRouter - GPT-4o"
                case .openrouter_gpt_4o_mini: return "OpenRouter - GPT-4o Mini"
                case .openrouter_llama_33_70b: return "OpenRouter - Llama 3.3 70B"
                case .openrouter_haiku_35: return "OpenRouter - Claude 3.5 Haiku"
                case .openrouter_custom: return "OpenRouter - Custom"
                
                case .openai_gpt4o_mini: return "OpenAI - GPT-4o Mini"
                case .openai_gpt4o: return "OpenAI - GPT-4o"
                case .openai_custom: return "OpenAI - Custom"
                
                case .ollama_gemma_3_1b: return "Ollama - Gemma 3 1B"
                case .ollama_gemma_3_4b: return "Ollama - Gemma 3 4B"
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
        Section("Debug") {
            Button(action: { BrowserStore.shared.model.clearAllAITags() }) {
                Text("Clear AI tags")
            }
        }
    }
}
