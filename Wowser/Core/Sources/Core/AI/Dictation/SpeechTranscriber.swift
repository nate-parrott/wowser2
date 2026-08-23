#if os(macOS)
import Foundation
import AVFoundation
import Speech

/// Thin wrapper over the system speech recognizer: streams microphone audio
/// into an `SFSpeechRecognizer` and reports the running transcript. One
/// session at a time.
@MainActor
final class SpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case speechNotAuthorized
        case microphoneNotAuthorized
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .speechNotAuthorized: return "Speech recognition isn't allowed. Enable it in System Settings › Privacy & Security › Speech Recognition."
            case .microphoneNotAuthorized: return "Microphone access isn't allowed. Enable it in System Settings › Privacy & Security › Microphone."
            case .recognizerUnavailable: return "Speech recognition isn't available right now."
            }
        }
    }

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Latest (partial or final) transcript for the current session.
    private(set) var transcript = ""
    var onTranscript: ((String, _ isFinal: Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private var finalContinuation: CheckedContinuation<String, Never>?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    // MARK: - Permissions

    static func requestPermissions() async throws {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { throw TranscriberError.speechNotAuthorized }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { throw TranscriberError.microphoneNotAuthorized }
    }

    // MARK: - Session

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.recognizerUnavailable }
        stop()
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onTranscript?(self.transcript, result.isFinal)
                    if result.isFinal {
                        self.finalContinuation?.resume(returning: self.transcript)
                        self.finalContinuation = nil
                    }
                }
                if let error {
                    // Cancellation after we've already stopped is routine; only
                    // surface errors that interrupt a live session.
                    if self.task != nil {
                        self.onError?(error)
                    }
                    self.finalContinuation?.resume(returning: self.transcript)
                    self.finalContinuation = nil
                }
            }
        }
    }

    /// Stops capturing and waits (briefly) for the recognizer's final pass.
    /// Returns the best transcript available.
    func finish(timeout: TimeInterval = 1.5) async -> String {
        guard request != nil else { return transcript }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        request?.endAudio()

        let text: String = await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                    self?.finalContinuation = c
                }
            }
            group.addTask { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return self?.transcript ?? ""
            }
            let first = await group.next() ?? transcript
            group.cancelAll()
            return first
        }
        finalContinuation?.resume(returning: transcript)
        finalContinuation = nil
        stop()
        return text.isEmpty ? transcript : text
    }

    /// Tears the session down immediately, discarding the result.
    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        request?.endAudio()
        request = nil
        let t = task
        task = nil
        t?.cancel()
        finalContinuation?.resume(returning: transcript)
        finalContinuation = nil
    }
}
#endif
