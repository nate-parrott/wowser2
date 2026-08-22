import Foundation
import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

// Coordinates dictation: resolving the target (a focused text field in the page, or the
// input bar / agent prompt), showing the target highlight on hover, running speech
// recognition, and committing the result.
public class DictationController: ObservableObject {
    public static let shared = DictationController()

    public enum Target: Equatable {
        case webField(webContentId: ID<WebContent>, frame: CGRect)
        case omnibox
    }

    // Window whose mic button is currently hovered (shows the target highlight)
    @Published public private(set) var hoverWindowID: ID<WindowState>?
    // Window with an active dictation session, and its locked-in target
    @Published public private(set) var recordingWindowID: ID<WindowState>?
    @Published public private(set) var lockedTarget: Target?

    let speech = SpeechRecognizer()

    private var subscriptions = Set<AnyCancellable>()
    #if os(macOS)
    private var interactionMonitor: Any?
    private var recordingKeyMonitor: Any?
    #endif

    public var isRecording: Bool { recordingWindowID != nil }

    init() {
        // Re-publish transcript changes so views observing the controller update live
        speech.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
    }

    // Call once at app startup (macOS)
    public func setup() {
        #if os(macOS)
        guard interactionMonitor == nil else { return }
        // Focused-text-field state is polled rather than observed. Poll (debounced) whenever
        // the user clicks or types; navigation and metadata changes trigger their own refresh.
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]) { [weak self] event in
            self?.pollFocusedFields()
            return event
        }
        #endif
    }

    // MARK: - Focus polling

    private func pollFocusedFields() {
        assertOnMainThread()
        let state = BrowserStore.shared.model
        for window in state.windows.values {
            if let pane = state.currentPane(forWindow: window.id),
               let webContent = BrowserStore.shared.liveWebContent(forId: pane.id) {
                webContent.refreshFocusedTextFieldDebounced()
            }
        }
    }

    // MARK: - Target resolution

    // The current dictation target for a window: the page's focused text field if there is
    // one, otherwise the input bar (which sends instructions to the agent).
    public func currentTarget(forWindow windowID: ID<WindowState>) -> Target {
        let state = BrowserStore.shared.model
        if let pane = state.currentPane(forWindow: windowID),
           let focusedField = pane.info.focusedTextField {
            return .webField(webContentId: pane.id, frame: focusedField.frame)
        }
        return .omnibox
    }

    // Target the UI should highlight for this window right now (locked while recording)
    public func displayTarget(forWindow windowID: ID<WindowState>) -> Target? {
        if recordingWindowID == windowID {
            return lockedTarget
        }
        if hoverWindowID == windowID {
            return currentTarget(forWindow: windowID)
        }
        return nil
    }

    // MARK: - Interaction

    public func micHovered(_ hovering: Bool, windowID: ID<WindowState>) {
        assertOnMainThread()
        if hovering {
            hoverWindowID = windowID
            pollFocusedFields()
        } else if hoverWindowID == windowID {
            hoverWindowID = nil
        }
    }

    // Cmd+D or a mic button click: starts dictation, or commits if already dictating
    public func toggleDictation(windowID: ID<WindowState>) {
        assertOnMainThread()
        if isRecording {
            commit()
        } else {
            startRecording(windowID: windowID)
        }
    }

    private func startRecording(windowID: ID<WindowState>) {
        guard !isRecording else { return }
        // Lock in the target
        lockedTarget = currentTarget(forWindow: windowID)
        recordingWindowID = windowID
        installRecordingKeyMonitor()
        Task { @MainActor [self] in
            do {
                try await self.speech.start()
            } catch {
                print("[🎤 Dictation] Failed to start: \(error)")
                self.endSession()
            }
        }
    }

    // Ends the session and inserts/sends what was dictated
    public func commit() {
        assertOnMainThread()
        guard let windowID = recordingWindowID, let target = lockedTarget else { return }
        let transcript = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        endSession()
        guard !transcript.isEmpty else { return }

        switch target {
        case .webField(let webContentId, _):
            commitToWebField(transcript: transcript, webContentId: webContentId, windowID: windowID)
        case .omnibox:
            // Dictating into the input bar sends the instruction to the browsing agent
            BrowserAgentManager.shared.startSession(
                instructions: transcript,
                source: .userInstruction(dictated: true),
                windowID: windowID
            )
        }
    }

    // Ends the session and discards the transcript
    public func cancel() {
        assertOnMainThread()
        endSession()
    }

    private func endSession() {
        speech.stop()
        recordingWindowID = nil
        lockedTarget = nil
        removeRecordingKeyMonitor()
    }

    private func commitToWebField(transcript: String, webContentId: ID<WebContent>, windowID: ID<WindowState>) {
        guard let webContent = BrowserStore.shared.getOrCreateWebContent(forId: webContentId, toBeActiveInWindow: windowID) else { return }
        if DefaultsKeys.dictationAICleanup.boolValue() {
            // Clean up the raw transcription with AI, streaming the result into the field
            Task { @MainActor in
                do {
                    let context = try? await webContent.readFocusedFieldContext()
                    let stream = try DictationCleanup.cleanedTextStream(
                        rawTranscript: transcript,
                        fieldValue: context?.fieldValue ?? "",
                        pageText: context?.pageText ?? "",
                        pageTitle: webContent.info.title,
                        url: webContent.info.url
                    )
                    for try await delta in stream {
                        webContent.insertTextIntoFocusedField(delta)
                    }
                } catch {
                    print("[🎤 Dictation] Cleanup failed, inserting raw transcript: \(error)")
                    webContent.insertTextIntoFocusedField(transcript)
                }
            }
        } else {
            webContent.insertTextIntoFocusedField(transcript)
        }
    }

    // MARK: - Key handling while recording

    private func installRecordingKeyMonitor() {
        #if os(macOS)
        guard recordingKeyMonitor == nil else { return }
        recordingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            switch event.keyCode {
            case 53: // Escape: end the session without committing
                self.cancel()
                return nil
            case 36, 76: // Return / keypad enter: commit
                self.commit()
                return nil
            default:
                return event
            }
        }
        #endif
    }

    private func removeRecordingKeyMonitor() {
        #if os(macOS)
        if let monitor = recordingKeyMonitor {
            NSEvent.removeMonitor(monitor)
            recordingKeyMonitor = nil
        }
        #endif
    }
}
