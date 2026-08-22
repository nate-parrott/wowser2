import SwiftUI

// Renders the contents of an agent-session tab (shown in place of a webview)
struct AgentTabView: View {
    var tabID: ID<Tab>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.tabs[tabID]?.agentInfo }) { info in
            ZStack {
                #if os(macOS)
                Color(NSColor.textBackgroundColor).edgesIgnoringSafeArea(.all)
                #endif
                if let info {
                    AgentTabContent(tabID: tabID, info: info)
                }
            }
        }
    }
}

private struct AgentTabContent: View {
    var tabID: ID<Tab>
    var info: AgentTabInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let session = BrowserAgentManager.shared.session(forTab: tabID) {
                    AgentTranscriptView(session: session)
                } else {
                    Text("This agent session has ended.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(24)
            .padding(.top, UIConstants.macHeaderHeight)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Agent")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                statusBadge
            }
            Text(info.instructions)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let statusText = info.statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(info.status == .error ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var statusBadge: some View {
        switch info.status {
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }
}

private struct AgentTranscriptView: View {
    @ObservedObject var session: BrowserAgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.thread.steps) { step in
                AgentStepView(step: step)
            }
        }
    }
}

private struct AgentStepView: View {
    var step: ThreadModel.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(step.toolUseLoop.enumerated()), id: \.offset) { _, toolStep in
                if let text = toolStep.initialResponse.asPlainText.nilIfEmpty {
                    messageText(text)
                }
                ForEach(Array(toolStep.initialResponse.functionCalls.enumerated()), id: \.offset) { _, call in
                    Label(call.name, systemImage: "gearshape")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let final = step.assistantMessageForUser?.asPlainText.nilIfEmpty {
                messageText(final)
            }
        }
    }

    @ViewBuilder private func messageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
