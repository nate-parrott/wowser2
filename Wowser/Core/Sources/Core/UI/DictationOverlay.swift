#if os(macOS)
import SwiftUI

// MARK: - Page overlay

/// Sits over a pane's webview. While the mic is hovered or a dictation session
/// targets a text field in this pane, draws a soft blurred outline around that
/// field, plus the live transcript underneath while listening.
struct DictationOverlay: View {
    var webContent: WebContent

    @ObservedObject private var controller = DictationController.shared

    /// The field to outline for this pane, if any (preview or active).
    private var field: WebContent.Info.FocusedEditable? {
        if let t = controller.target, case .webField(let pane, let f) = t, pane == webContent.id { return f }
        if let t = controller.hoverPreview, case .webField(let pane, let f) = t, pane == webContent.id { return f }
        return nil
    }

    private var isActive: Bool {
        controller.isActive && controller.target?.paneID == webContent.id && controller.target?.isOmnibox == false
    }

    /// Terminal tabs: the whole pane is the target.
    private var isTerminalTarget: Bool {
        if let t = controller.target, case .terminal(let pane) = t, pane == webContent.id { return true }
        if let t = controller.hoverPreview, case .terminal(let pane) = t, pane == webContent.id { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            if isTerminalTarget {
                ZStack(alignment: .bottomLeading) {
                    DictationOutline(active: isActive, cornerRadius: 6)
                        .padding(3)
                    if isActive {
                        DictationTranscriptBubble(text: controller.transcript, phase: controller.phase)
                            .frame(maxWidth: min(520, geo.size.width - 32), alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else if let field {
                let zoom = webContent.wkWebview?.pageZoom ?? 1
                let raw = CGRect(x: field.x * zoom, y: field.y * zoom, width: field.width * zoom, height: field.height * zoom)
                let frame = raw.intersection(CGRect(origin: .zero, size: geo.size)).insetBy(dx: -4, dy: -4)
                if !frame.isNull, frame.width > 0, frame.height > 0 {
                    ZStack(alignment: .topLeading) {
                        DictationOutline(active: isActive)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)

                        if isActive {
                            DictationTranscriptBubble(text: controller.transcript, phase: controller.phase)
                                .frame(maxWidth: max(180, min(frame.width, geo.size.width - 16)), alignment: .leading)
                                .offset(x: max(8, min(frame.minX, geo.size.width - 200)), y: bubbleY(fieldFrame: frame, in: geo.size))
                        }
                    }
                }
            }
            if let error = controller.errorText, controller.hoverPreview?.paneID == webContent.id || controller.target == nil {
                Text(error)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
            }
        }
        .allowsHitTesting(false)
    }

    private func bubbleY(fieldFrame: CGRect, in size: CGSize) -> CGFloat {
        // Below the field if there's room, else above it.
        let below = fieldFrame.maxY + 8
        return below + 60 < size.height ? below : max(8, fieldFrame.minY - 68)
    }
}

/// Blurry accent outline used for both the page field and the omnibox.
struct DictationOutline: View {
    var active: Bool
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape
                .strokeBorder(active ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.8), lineWidth: 3)
                .blur(radius: 6)
            shape
                .strokeBorder(active ? Color.red.opacity(0.9) : Color.accentColor.opacity(0.9), lineWidth: 1.5)
        }
    }
}

// MARK: - Transcript

/// Live transcript under a page field while dictating.
private struct DictationTranscriptBubble: View {
    var text: String
    var phase: DictationController.Phase

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)
            Text(displayText)
                .font(.system(size: 13))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var displayText: String {
        switch phase {
        case .starting: return "Starting…"
        case .committing: return text.isEmpty ? "Finishing…" : text
        default: return text.isEmpty ? "Listening… (Return to insert, Esc to cancel)" : text
        }
    }
}

/// Replaces the omnibox's URL text while dictating to the agent.
struct DictationTranscriptView: View {
    var fgColor: HSBA?
    var fontSize: CGFloat

    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: fontSize, weight: .semibold))
            Text(displayText)
                .font(.system(size: fontSize))
                .foregroundStyle(fgColor?.color ?? Color.primary)
                .opacity(controller.transcript.isEmpty ? 0.5 : 1)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var displayText: String {
        switch controller.phase {
        case .starting: return "Starting…"
        case .committing: return controller.transcript.isEmpty ? "Finishing…" : controller.transcript
        default: return controller.transcript.isEmpty ? "Ask the agent… (Return to send, Esc to cancel)" : controller.transcript
        }
    }
}

/// Applied to the omnibox text area: reports whether the live transcript
/// should replace the omnibox text (dictating to the agent from this pane).
/// The outline itself is drawn around the whole toolbar / new-tab card by
/// `DictationCardHighlight`.
struct DictationOmniboxHighlight: ViewModifier {
    var paneID: ID<WebContent>?
    @Binding var shown: Bool

    @ObservedObject private var controller = DictationController.shared

    private var isActiveHere: Bool {
        if let t = controller.target, case .omnibox(let pane, _) = t { return pane == paneID }
        return false
    }

    func body(content: Content) -> some View {
        content.onAppearOrChange(of: isActiveHere) { shown = $0 }
    }
}

/// Outlines its content (the whole toolbar, or the new-tab page's backdrop
/// card) while the mic is hovered with this pane's omnibox as target, or while
/// dictating to the agent from this pane.
struct DictationCardHighlight: ViewModifier {
    var paneID: ID<WebContent>?
    var cornerRadius: CGFloat
    var enabled = true

    @ObservedObject private var controller = DictationController.shared

    private var isActiveHere: Bool {
        if let t = controller.target, case .omnibox(let pane, _) = t { return pane == paneID }
        return false
    }

    private var isPreviewHere: Bool {
        if let t = controller.hoverPreview, case .omnibox(let pane, _) = t { return pane == paneID }
        return false
    }

    func body(content: Content) -> some View {
        content.overlay {
            if enabled, isActiveHere || isPreviewHere {
                DictationOutline(active: isActiveHere, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif

/// Cross-platform shim for `DictationCardHighlight`.
struct DictationCardHighlightIfAvailable: ViewModifier {
    var paneID: ID<WebContent>?
    var cornerRadius: CGFloat
    var enabled = true

    func body(content: Content) -> some View {
        #if os(macOS)
        content.modifier(DictationCardHighlight(paneID: paneID, cornerRadius: cornerRadius, enabled: enabled))
        #else
        content
        #endif
    }
}

/// Cross-platform shim so ToolbarView can apply the highlight unconditionally.
struct DictationOmniboxHighlightIfAvailable: ViewModifier {
    var paneID: ID<WebContent>?
    @Binding var shown: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.modifier(DictationOmniboxHighlight(paneID: paneID, shown: $shown))
        #else
        content
        #endif
    }
}
