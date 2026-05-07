import SwiftUI

#if os(macOS)
import AppKit
#endif

struct MCPSettings: View {
    @AppStorage(DefaultsKeys.mcpServerURL.rawValue) private var mcpURL: String = ""
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Text("Install in Claude Code")
                    .font(.headline)
                Text("Run this once. After that, `claude` in any terminal can drive the browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CopyableCommand(text: claudeAddCommand)
                    .padding(.top, 4)
            }

//            Section {
//                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
//                    VStack(alignment: .leading, spacing: 14) {
//                        VStack(alignment: .leading, spacing: 4) {
//                            Text("Server URL").font(.caption).foregroundStyle(.secondary)
//                            HStack {
//                                Text(displayURL)
//                                    .font(.system(.body, design: .monospaced))
//                                    .textSelection(.enabled)
//                                Spacer()
//                                CopyButton(text: displayURL)
//                            }
//                            Text("The auth key is baked into the URL path. Anyone with the URL can drive this browser, so don't share it.")
//                                .font(.caption).foregroundStyle(.secondary)
//                        }
//
//                        VStack(alignment: .leading, spacing: 4) {
//                            Text("Other MCP clients").font(.caption).foregroundStyle(.secondary)
//                            CopyableCommand(text: mcpJSONSnippet)
//                        }
//
//                        VStack(alignment: .leading, spacing: 6) {
//                            Text("Tools").font(.caption).foregroundStyle(.secondary)
//                            ToolRow(name: "run_browser_js", desc: "Run async JS in the privileged BrowserJS environment.")
//                            ToolRow(name: "save_browser_helper_file", desc: "Persist a JS helper that gets prepended to every run_browser_js eval.")
//                            ToolRow(name: "read_browser_helper_file", desc: "Read one helper, or list all.")
//                            ToolRow(name: "get_browser_js_docs", desc: "Return the BrowserJS .d.ts. Call this first.")
//                        }
//                    }
//                    .padding(.top, 8)
//                }
//            }
        }
    }

    private var displayURL: String { mcpURL.isEmpty ? "<starting…>" : mcpURL }

    private var claudeAddCommand: String {
        "claude mcp add --transport http \(isProd() ? "tangerine" : "tangerinedev") \(displayURL)"
    }

    private var mcpJSONSnippet: String {
        """
        {
          "mcpServers": {
            "wowser": {
              "type": "http",
              "url": "\(displayURL)"
            }
          }
        }
        """
    }
}

private struct CopyableCommand: View {
    var text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(text)
                .font(.system(.body, design: .monospaced))
//                .textSelection(.enabled) // for some reason this crashes SwiftUI on second appearance
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
//        .padding(8)
//        .background(Color.secondary.opacity(0.08))
//        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ToolRow: View {
    var name: String
    var desc: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(.body, design: .monospaced))
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CopyButton: View {
    var text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
