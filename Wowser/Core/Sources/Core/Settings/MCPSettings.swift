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

            #if os(macOS)
            Section {
                NetworkProxyKillSwitchSection()
            }

            Section {
                HTTPSCaptureSettingsSection()
            }
            #endif

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
        "claude mcp add --scope user --transport http \(isProd() ? "wowser" : "wowserdev") \(displayURL)"
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

#if os(macOS)
/// Opt-in switch for the local capturing proxy. Off by default (registered
/// default sets `disableNetworkProxy` true): all webview traffic flows
/// directly with no HTTP capture and no HTTPS MITM.
private struct NetworkProxyKillSwitchSection: View {
    @AppStorage(DefaultsKeys.disableNetworkProxy.rawValue) private var disabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $disabled.not()) {
                Text("Enable network capture")
                    .font(.headline)
            }
            .toggleStyle(.switch)

            Text("Routes webview traffic through the local capturing proxy so agents can inspect HTTP (and, with the certificate below, HTTPS) requests. Turn it off if pages fail to load. Takes effect for new tabs (reload existing tabs or relaunch to apply everywhere).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Lets the user install/trust the local MITM root so HTTPS traffic on
/// allowlisted origins can be captured (`browser.net.*`). Without this, WebKit
/// rejects the forged certs for proxied TLS, so allowlisted HTTPS origins are
/// left untouched (loaded normally but uncaptured).
private struct HTTPSCaptureSettingsSection: View {
    @State private var trusted: Bool = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HTTPS capture")
                .font(.headline)
            Text("Plain HTTP is captured automatically. To also capture HTTPS traffic on origins you enable for capture, the agent's local certificate must be trusted. macOS will ask for your password.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: trusted ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(trusted ? .green : .secondary)
                Text(trusted ? "Certificate installed — HTTPS capture enabled" : "Certificate not installed")
                    .font(.callout)
            }

            HStack {
                if trusted {
                    Button("Remove Certificate") { run { try LocalCA.shared.uninstallRootTrust() } }
                } else {
                    Button("Install Certificate…") { run { try LocalCA.shared.installRootAsTrusted() } }
                        .buttonStyle(.borderedProminent)
                }
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        Task.detached {
            let t = LocalCA.shared.isRootTrusted(forceRefresh: true)
            await MainActor.run { self.trusted = t }
        }
    }

    private func run(_ op: @escaping () throws -> Void) {
        working = true
        errorText = nil
        Task.detached {
            var failure: String?
            do { try op() } catch { failure = "\(error)" }
            let t = LocalCA.shared.isRootTrusted(forceRefresh: true)
            await MainActor.run {
                self.trusted = t
                self.errorText = failure
                self.working = false
            }
        }
    }
}
#endif

struct CopyButton: View {
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
        #else
        // TODO: Use UIPasteboard
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
