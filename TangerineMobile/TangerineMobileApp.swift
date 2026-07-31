import SwiftUI
import Core

@main
struct TangerineMobileApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            DefaultsKeys.adblock.rawValue: true,
            DefaultsKeys.cookieBannerBlock.rawValue: true,
            DefaultsKeys.autoDarkMode.rawValue: true,
            DefaultsKeys.animateNewTabs.rawValue: true,
            DefaultsKeys.searchEngine.rawValue: SearchEngine.clean.rawValue,
            DefaultsKeys.Chatbot.rawValue: Chatbot.claude.rawValue,
            DefaultsKeys.preserveWindowsAcrossRestarts.rawValue: true,
            DefaultsKeys.cleanModeForRecipes.rawValue: true,
            DefaultsKeys.autoOrganizeTabs.rawValue: true,
            DefaultsKeys.enableGoDirectQueries.rawValue: true,
//            DefaultsKeys.homepagePrompt.rawValue: "Create a fun, engaging, interesting homepage with the latest news.",
            DefaultsKeys.llmChoice.rawValue: LLMChoice.openai_gpt_5_4_nano.rawValue,
//            DefaultsKeys.openAIKey.rawValue: "[REMOVED-OPENAI-KEY]"
        ])
        
        Preheat.preheat()
    }
    
    var body: some Scene {
//        WindowGroup {
//            Content()
//        }
        WindowGroup(for: ID<WindowState>.self) { $windowID in
            Content(windowID: windowID)
        } defaultValue: {
            BrowserStore.shared.model.newWindow().id
        }
    }
}

struct Content: View {
    var windowID: ID<WindowState>
    @State private var lastBackgroundDate: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            MobileContentView(windowID: windowID)
        }
//        .onAppear {
//            if windowID == nil {
//                windowID = BrowserStore.shared.model.newWindow().id
//                if let windowID {
//                    BrowserStore.shared.model.windows[windowID]?.searchOverlayActive = true
//                }
//            }
//        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                let now = Date()
                if lastBackgroundDate == nil || now.timeIntervalSince(lastBackgroundDate!) > UIConstants.mobileKeyboardReopenAfterIdleTime {
                    BrowserStore.shared.model.windows[windowID]?.searchOverlayActive = true
                }
            } else if newPhase == .background {
                lastBackgroundDate = Date()
            }
        }
    }
}
