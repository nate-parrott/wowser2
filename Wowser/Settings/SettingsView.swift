import SwiftUI
import Core

struct SettingsView: View {
    @AppStorage(DefaultsKeys.adblock.rawValue) private var adblockEnabled = false
    @AppStorage(DefaultsKeys.autoDarkMode.rawValue) private var autoDarkModeEnabled = false
    
    var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Enable AdBlock", isOn: $adblockEnabled)
                    .help("Blocks ads on websites using built-in filter lists")
                
                Toggle("Auto Dark Mode", isOn: $autoDarkModeEnabled)
                    .help("Automatically adjusts website appearance to match system dark mode when sites don't support it natively")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 400)
    }
}
