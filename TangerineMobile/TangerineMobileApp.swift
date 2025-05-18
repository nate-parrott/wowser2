//
//  TangerineMobileApp.swift
//  TangerineMobile
//
//  Created by Nate Parrott on 5/17/25.
//

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
            DefaultsKeys.homepagePrompt.rawValue: "Create a fun, engaging, interesting homepage with the latest news.",
            DefaultsKeys.llmChoice.rawValue: LLMChoice.openai_gpt4o_mini.rawValue,
            DefaultsKeys.openAIKey.rawValue: "[REMOVED-OPENAI-KEY]"
        ])
        
        Preheat.preheat()
    }
    
    var body: some Scene {
        WindowGroup {
            Content()
        }
    }
}

struct Content: View {
    @State private var windowID: ID<WindowState>?
    @State private var lastBackgroundDate: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let windowID {
                MobileContentView(windowID: windowID)
            }
        }
        .onAppear {
            if windowID == nil {
                windowID = BrowserStore.shared.model.newWindow().id
                if let windowID {
                    BrowserStore.shared.model.windows[windowID]?.searchOverlayActive = true
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                let now = Date()
                if lastBackgroundDate == nil || now.timeIntervalSince(lastBackgroundDate!) > UIConstants.mobileKeyboardReopenAfterIdleTime {
                    if let windowID {
                        BrowserStore.shared.model.windows[windowID]?.searchOverlayActive = true
                    }
                }
            } else if newPhase == .background {
                lastBackgroundDate = Date()
            }
        }
    }
}
