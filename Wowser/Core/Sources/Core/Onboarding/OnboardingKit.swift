import SwiftUI
//
//  OnboardingKit.swift
//  Core
//
//  Created by Nate Parrott on 10/4/26.
//

/*
 Flow:
 
 One place for all your work
 [Get started]
 
 -----
 
 Transfer logins and history, so you don't have to log in to everything again
 
 # Chrome
 [Profile 1 - usage amt] [Import]
 [Profile 2 - usage amt] [Import]
 [Profile 3 - usage amt] [Import]
 // -- etc --
 Imports cookies, logins, passwords into autofill [i] // allows checking/unchecking
 
 # Safari
 [Drop passwords exported]
 
 [Skip] // or 'done' if you pick some
 
 // Creates one space + profile per import; pins top sites as faves
 
 -----
 
 Set as default browser?
 
 [Set as Default] [Not yet]
 
 -----
 
 Connect your AI
 > Use your existing AI subscription from the browser, for answering quick questions or performing tasks.
 > We'll add the Wowser MCP, which lets it do anything in the browser that you can do.
 
 [Use Claude]
 // Subtext: uses Claude for agent chats and adds the Wowser MCP, so Claude can access the browser.
 [Use Codex] (disabled)
 // Subtext: unavailable
 
 [Skip for now]
 
 -----
 
 Limitations:
 
 - Very experimental
 - No passkeys
 - Some sites don't work
 - Not security-tested
 
 [I understand]
 
 -----
 
 Enable other goodies
 
 [x] Ad blocker
 [x] Auto dark mode on websites
 [ ] Memory -- let your AI full-text search your browsing activity
 
 -----
 
 Add a few projects
 
 [Icon] [Title] [Folder] // repeat once for each project added; maybe suggest some using ai from history?
 [Text field: placeholder 'Finding an apartment'] [+ Folder] [Add]
 [Add folder]
 // Subtitle: Good for coding projects
 
 -----
 
 Learn some neat tricks
 
 [ ] Option-click a link to open in split ([try it](http://example.com))
 [ ] Click in the top bar (CMD-L) and ask a question about this page (try it!)
 [ ] Swipe down with three fingers to cycle thru recent tabs (or press CMD-E) (try it!)
 [ ] Drag an image into the sidebar to set it as a space background (try it -- provides image thumbnail from preset unsplash images)
 
 */

// Components: Button, Screen, Toggle, Well, FeatheredScroll, Radio

private struct OnboardingScreen<C: View, Footer: View>: View {
    @ViewBuilder var content: () -> C
    @ViewBuilder var footer: () -> Footer
    
    var mainMaxWidth: CGFloat = 700
    var padding: CGFloat {
        smallViewport ? 20 : 50
    }
    
    @State private var smallViewport = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                content()
                    .padding(padding)
                    .frame(maxWidth: mainMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }
            .modifier(FeatherTopAndBottom(featherHeight: padding * 0.8))
            
            HStack {
                footer()
            }
            .padding(.horizontal, padding)
            .padding(.bottom, padding)
        }
        .controlSize(smallViewport ? .regular : .extraLarge)
        .measureSize({ self.smallViewport = $0.width < 500 || $0.height < 500 })
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.05)
        }
    }
}

struct FeatherTopAndBottom: ViewModifier {
    var featherHeight: CGFloat = 20
    
    @State private var contentHeight: CGFloat = 100
    
    func body(content: Content) -> some View {
        let x = featherHeight / max(1, contentHeight)
        content.mask {
            LinearGradient(stops: [
                Gradient.Stop(color: Color.clear, location: 0),
                Gradient.Stop(color: Color.black, location: x),
                Gradient.Stop(color: Color.black, location: 1 - x),
                Gradient.Stop(color: Color.clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .measureSize({ self.contentHeight = $0.height })
    }
}

private struct DividedStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { i in
                    subviews[i]
                    if i < subviews.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

private struct OnboardingDemoView: View {
    var body: some View {
        OnboardingScreen(content: {
            Form {
                Section {
                    Text("hey!")
                }
            }
            .formStyle(.grouped)
        }, footer: {
            Button(action: {}) {
                Text("Continue")
            }
        })
    }
}

#Preview {
    OnboardingDemoView()
}
