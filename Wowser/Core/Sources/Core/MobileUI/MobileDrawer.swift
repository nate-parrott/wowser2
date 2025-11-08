//
//  MobileDrawer.swift
//  Core
//
//  Created by Nate Parrott on 6/1/25.
//

import SwiftUI

struct MobileDrawer: View {
    @Environment(\.windowID) private var windowID
    var body: some View {
        if let windowID {
            SidebarSwipeView(windowID: windowID)
        }
    }
}

extension View {
    @ViewBuilder
    func withMobileDrawerContainer() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        
        self
            .background(.regularMaterial)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 0)
    }
}
