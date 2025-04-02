import SwiftUI
import Core

struct SettingsView: View {
    @AppStorage(DefaultsKeys.adblock.rawValue) private var adblockEnabled = false
    @AppStorage(DefaultsKeys.autoDarkMode.rawValue) private var autoDarkModeEnabled = false
    @AppStorage(DefaultsKeys.topbarLocked.rawValue) private var topbarLocked = false
    
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
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 400)
    }
}

extension Binding where Value == Bool {
    func not() -> Binding<Bool> {
        .init(get: { !self.wrappedValue }, set: { self.wrappedValue = !$0 })
    }
}
