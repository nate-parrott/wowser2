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
    var body: some Scene {
        WindowGroup {
            Content()
        }
    }
}

struct Content: View {
    @State private var windowID: ID<WindowState>?
    
    var body: some View {
        ZStack {
            if let windowID {
                MobileContentView(windowID: windowID)
            }
        }
        .onAppear {
            if windowID == nil {
                windowID = BrowserStore.shared.model.newWindow().id
//                windowID = WindowIDVendor.shared.vendNextWindowID()
            }
        }
    }
}
