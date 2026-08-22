import SwiftUI

// MARK: - Mic buttons

// Two mic buttons exist (page toolbar + new-tab page input); they're similar but subtly different.
public struct DictationMicButton: View {
    public enum Style {
        case page // trailing toolbar button on a normal page
        case newTabPage // shown in the large input on the new tab page
    }

    var style: Style

    @Environment(\.windowID) private var windowID
    @ObservedObject private var controller = DictationController.shared

    public init(style: Style) {
        self.style = style
    }

    private var isRecordingHere: Bool {
        windowID != nil && controller.recordingWindowID == windowID
    }

    public var body: some View {
        Button(action: toggle) {
            Image(systemName: iconName)
                .imageScale(style == .newTabPage ? .large : .medium)
                .foregroundStyle(isRecordingHere ? Color.red : Color.primary)
                .modifier(RecordingPulseModifier(recording: isRecordingHere))
        }
        .buttonStyle(ToolbarButtonStyle())
        .onHover { hovering in
            if let windowID {
                controller.micHovered(hovering, windowID: windowID)
            }
        }
        .help(isRecordingHere ? "Finish Dictation (⌘D)" : "Dictate (⌘D)")
    }

    private var iconName: String {
        if isRecordingHere {
            return "mic.fill"
        }
        switch style {
        case .page: return "mic"
        case .newTabPage: return "mic.fill"
        }
    }

    private func toggle() {
        if let windowID {
            controller.toggleDictation(windowID: windowID)
        }
    }
}

private struct RecordingPulseModifier: ViewModifier {
    var recording: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(recording && dimmed ? 0.45 : 1)
            .animation(recording ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: dimmed)
            .onChange(of: recording) { rec in
                dimmed = rec
            }
    }
}

// MARK: - Target highlight

// Soft blurry outline drawn around the dictation target
struct DictationHighlight: View {
    var recording: Bool
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .strokeBorder(Color.accentColor.opacity(recording ? 0.9 : 0.6), lineWidth: 2.5)
            .blur(radius: 3)
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: Color.accentColor.opacity(0.4), radius: 8)
            .modifier(RecordingPulseModifier(recording: recording))
            .allowsHitTesting(false)
    }
}

// Draws the highlight over the focused text field inside a web pane
struct DictationWebFieldOverlay: View {
    var webContentId: ID<WebContent>
    var paneFocused: Bool

    @Environment(\.windowID) private var windowID
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        // Observe the focused-field frame so the highlight tracks it
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state in
            state.tabInfo(forWebContentId: webContentId)?.focusedTextField
        }) { focusedField in
            ZStack(alignment: .topLeading) {
                if let frame = highlightFrame(focusedField: focusedField) {
                    DictationHighlight(recording: controller.isRecording)
                        .frame(width: max(frame.width + 12, 20), height: max(frame.height + 12, 20))
                        .offset(x: frame.minX - 6, y: frame.minY - 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .animation(.niceDefault(duration: 0.15), value: focusedField)
        }
    }

    private func highlightFrame(focusedField: FocusedTextField?) -> CGRect? {
        guard let windowID, paneFocused else { return nil }
        switch controller.displayTarget(forWindow: windowID) {
        case .webField(let targetId, let lockedFrame):
            guard targetId == webContentId else { return nil }
            // While recording the target is locked, but keep tracking the live frame if available
            return focusedField?.frame ?? lockedFrame
        case .omnibox, nil:
            return nil
        }
    }
}

// Applies the highlight around the omnibox / input bar when it's the dictation target
struct DictationOmniboxHighlight: ViewModifier {
    @Environment(\.windowID) private var windowID
    @ObservedObject private var controller = DictationController.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let windowID, controller.displayTarget(forWindow: windowID) == .omnibox {
                DictationHighlight(recording: controller.isRecording)
                    .padding(-2)
            }
        }
    }
}

// MARK: - Agent working indicator

// Shown in place of the URL in the input bar while an attached (hidden) agent tab is working.
// Clicking reveals the agent's tab.
struct AgentWorkingIndicator: View {
    var windowID: ID<WindowState>

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ShimmeringText(text: "Agent is working…")
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                AgentWorkingGradient()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("An agent is working on your task. Click to view.")
    }

    private func reveal() {
        BrowserAgentManager.shared.revealMostRecentAttachedTab(inWindow: windowID)
    }
}

private struct ShimmeringText: View {
    var text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 2.5) / 2.5)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: (geo.size.width * 1.5) * phase - geo.size.width * 0.5)
                    }
                    .mask(Text(text).font(.system(size: 14)))
                    .allowsHitTesting(false)
                }
        }
    }
}

// Subtle blurred, slowly-oscillating gradient behind the indicator
private struct AgentWorkingGradient: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * 0.5, height: geo.size.width * 0.5)
                        .offset(x: geo.size.width * 0.25 * sin(t * 0.7), y: 0)
                    Circle()
                        .fill(Color.purple)
                        .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                        .offset(x: geo.size.width * 0.25 * cos(t * 0.5), y: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .blur(radius: 24)
            .opacity(0.15)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}
