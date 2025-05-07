import SwiftUI
import Core

struct HomepageSettings: View {
    @AppStorage(DefaultsKeys.homepagePrompt.rawValue) private var homepagePrompt = ""
    
    var body: some View {
        Form {
            Section("Homepage Prompt") {
                InputTextField(text: $homepagePrompt, options: .init(placeholder: "Prompt..."), onEvent: {_ in () })
                    .frame(height: 150)
//                TextEditor(text: $homepagePrompt)
//                TextField("Homepage Prompt", text: $homepagePrompt)
//                    .help("Enter a prompt to customize your AI-generated homepage")
            }
            
            Section("Show homepage in these profiles...") {
                ProfilesList()
            }
        }
    }
}

private struct ProfilesList: View {
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            ProfilesSnapshot(profiles: state.profiles)
        } main: { snapshot in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.profiles.values.sorted(by: { $0.creationOrder < $1.creationOrder }), id: \.id.raw) { profile in
                    ProfileRow(profile: profile)
                }
            }
        }
    }
}

private struct ProfilesSnapshot: Equatable {
    let profiles: [ID<Profile>: Profile]
}

private struct ProfileRow: View {
    let profile: Profile
    @State private var isFaved: Bool = false
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.isHomepageFaved(profileID: profile.id)
        } main: { isFavedValue in
            HStack {
                Toggle(isOn: $isFaved) {
                    Text(profile.title ?? profile.emoji ?? "Profile")
                }
                .onChange(of: isFaved) { newValue in
                    BrowserStore.shared.setHomepageFaved(newValue, profileID: profile.id)
                }
                
                Spacer()
                
                Button("Refresh") {
//                    GeneratedPageStore.shared.modify { state in
//                        state.pages.removeValue(forKey: .homepage)
//                    }
                    GeneratedPageStore.shared.ensureGeneratedPageLoaded(for: .homepage, forceRefresh: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .onAppear {
                isFaved = isFavedValue
            }
            .onChange(of: isFavedValue) { newValue in
                isFaved = newValue
            }
        }
    }
}

// BrowserState extension for homepage favorites
extension BrowserState {
    func isHomepageFaved(profileID: ID<Profile>) -> Bool {
        guard let profile = profiles[profileID] else { return false }
        
        return profile.manualFavorites.contains { favoriteTabID in
            if let tab = tabs[favoriteTabID],
               let pane = tab.panes.first,
               let url = pane.info.url,
               let key = GeneratedPageKey(url: url),
               case .homepage = key {
                return true
            }
            return false
        }
    }
}

// BrowserStore extensions for homepage favorites
extension BrowserStore {
    func isHomepageFaved(profileID: ID<Profile>) -> Bool {
        return model.isHomepageFaved(profileID: profileID)
    }
    
    func setHomepageFaved(_ value: Bool, profileID: ID<Profile>) {
        modify { state in
            if value {
                // Add homepage as a favorite if not already present
                if !state.isHomepageFaved(profileID: profileID) {
                    let homepageURL = GeneratedPageKey.homepage.url
                    let tab = Tab.newTabWithURL(homepageURL, title: "Homepage")
                    state.insertTab(tab, intoProfileFavoritesAtIndex: 0, profile: profileID)
//                    state.modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
//                        pane.baseInfo = WebContent.Info(url: homepageURL)
//                    }
                }
            } else {
                // Remove homepage from favorites
                if let profile = state.profiles[profileID] {
                    let homepageTabIDs = profile.manualFavorites.filter { favTabID in
                        if let tab = state.tabs[favTabID],
                           let pane = tab.panes.first,
                           let url = pane.info.url,
                           let key = GeneratedPageKey(url: url),
                           case .homepage = key {
                            return true
                        }
                        return false
                    }
                    
                    for tabID in homepageTabIDs {
                        state.profiles[profileID]?.manualFavorites.removeAll { $0 == tabID }
                        state._removeTab_unsafe_doesntCloseWebContent(tabId: tabID, removeFromParent: true)
                    }
                }
            }
        }
    }
}
