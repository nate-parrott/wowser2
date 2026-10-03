import SwiftUI

/// Settings › Credits: the photographers behind the built-in space
/// backgrounds, and the open-source projects the browser is built on.
struct CreditsSettings: View {
    private static let openSource: [(name: String, url: String)] = [
        ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm"),
        ("MCP Swift SDK", "https://github.com/modelcontextprotocol/swift-sdk"),
        ("SwiftNIO", "https://github.com/apple/swift-nio"),
        ("Swift Certificates", "https://github.com/apple/swift-certificates"),
        ("DominantColors", "https://github.com/DenDmitriev/DominantColors"),
        ("Motion", "https://github.com/b3ll/Motion"),
        ("Ink", "https://github.com/johnsundell/ink"),
        ("EasyList", "https://easylist.to"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(BuiltinSpaceBackground.all) { background in
                    CreditRow(title: background.title, detail: "Photo by \(background.photographer) on Unsplash", url: background.photoPageURL)
                }
            } header: {
                Text("Background Images")
            }

            Section("Open Source") {
                ForEach(Self.openSource, id: \.name) { item in
                    if let url = URL(string: item.url) {
                        CreditRow(title: item.name, detail: url.host() ?? "", url: url)
                    }
                }
            }
        }
    }
}

private struct CreditRow: View {
    var title: String
    var detail: String
    var url: URL

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .help(url.absoluteString)
        }
    }
}

#Preview {
    CreditsSettings()
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
}
