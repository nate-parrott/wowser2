import SwiftUI

/// Settings → AI → Features: one backend picker per MicroAIFeature.
struct MicroAIFeaturesSection: View {
    /// Observed only to re-render when a backend changes; values go through `MicroAI`.
    @AppStorage(DefaultsKeys.microAIBackends.rawValue) private var backendsJSON = ""

    var body: some View {
        let _ = backendsJSON
        Section {
            ForEach(MicroAIFeature.allCases) { feature in
                Picker(selection: Binding(
                    get: { MicroAI.backend(for: feature) },
                    set: { MicroAI.setBackend($0, for: feature) }
                )) {
                    ForEach(MicroAIBackend.allCases, id: \.self) { backend in
                        Text(backend.title).tag(backend)
                    }
                } label: {
                    Text(feature.title)
                    Text(feature.detail)
                }
            }
        } header: {
            Text("Features")
        } footer: {
            if !MicroAI.onDeviceAvailable {
                Text("The on-device model isn't available. Turn on Apple Intelligence in System Settings to use it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Whether any feature currently uses `backend` (drives which settings sections show).
    static func anyFeatureUses(_ backend: MicroAIBackend) -> Bool {
        MicroAIFeature.allCases.contains { MicroAI.backend(for: $0) == backend }
    }
}
