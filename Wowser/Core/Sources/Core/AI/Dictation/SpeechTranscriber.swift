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

    /// Merges per-utterance recognizer results into one running transcript.
    private var accumulator = TranscriptAccumulator()
    /// Latest (partial or final) transcript for the current session.
    var transcript: String { accumulator.transcript }
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
        accumulator = TranscriptAccumulator()

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
                    self.accumulator.absorb(result.bestTranscription.formattedString, finalizesUtterance: result.speechRecognitionMetadata != nil || result.isFinal)
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

/// Folds speech-recognizer results into one running transcript. Pure, so the
/// utterance-boundary rules can be unit-tested (`TranscriptAccumulatorTests`).
struct TranscriptAccumulator {
    /// Everything heard so far.
    private(set) var transcript = ""
    /// Utterances the recognizer has finished (and may stop reporting).
    private var committed = ""
    private var currentUtterance = ""
    /// The utterance most recently moved into `committed`, so a re-report of
    /// it (the final result after `endAudio` often repeats it) isn't doubled.
    private var lastFinalizedUtterance: String?

    /// Folds a recognition result (its `bestTranscription.formattedString`;
    /// `finalizesUtterance` = it has `speechRecognitionMetadata` or `isFinal`)
    /// into `transcript`, carrying earlier
    /// utterances forward when the recognizer drops them.
    ///
    /// Utterance boundaries:
    /// - `finalizesUtterance` (the recognizer attaches `speechRecognitionMetadata`
    ///   only to a result that ends an utterance) — its text is committed as-is.
    /// - Fallback, in case a boundary arrives without it: the new text shares
    ///   no leading word with the utterance in progress and is much shorter,
    ///   i.e. it's a fresh utterance rather than a revision of the partial.
    ///
    /// (Segment timestamps are NOT reliable for this: partial results often
    /// report 0 while the final pass reports real times, which used to make a
    /// finished utterance look like a new one and get appended twice — while a
    /// genuinely new utterance whose partials also reported 0 overwrote the
    /// previous one.)
    mutating func absorb(_ newText: String, finalizesUtterance: Bool) {
        var text = newText

        // Some recognizer modes keep reporting everything since the start
        // instead of resetting per utterance: strip what's already committed.
        let committedWords = Self.words(committed)
        if !committedWords.isEmpty, Array(Self.words(text).prefix(committedWords.count)) == committedWords {
            text = Self.dropLeadingWords(text, count: committedWords.count)
            if Self.words(text).isEmpty { return }
        }
        if currentUtterance.isEmpty, let last = lastFinalizedUtterance, Self.sameWords(text, last) {
            // A repeat of the utterance we already committed.
            return
        }
        if !currentUtterance.isEmpty, Self.isNewUtterance(text, after: currentUtterance) {
            commitCurrentUtterance()
        }
        currentUtterance = text
        transcript = Self.join(committed, currentUtterance)
        if finalizesUtterance {
            commitCurrentUtterance()
        }
    }

    private mutating func commitCurrentUtterance() {
        guard !currentUtterance.isEmpty else { return }
        committed = Self.join(committed, currentUtterance)
        lastFinalizedUtterance = currentUtterance
        currentUtterance = ""
        transcript = committed
    }

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// `text` minus its first `count` words (and the punctuation/space after them).
    static func dropLeadingWords(_ text: String, count: Int) -> String {
        var remaining = count
        var inWord = false
        var idx = text.startIndex
        while idx < text.endIndex {
            let isWordChar = text[idx].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if isWordChar, !inWord {
                if remaining == 0 { break }
                remaining -= 1
            }
            inWord = isWordChar
            idx = text.index(after: idx)
        }
        return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sameWords(_ a: String, _ b: String) -> Bool {
        let wa = words(a)
        return !wa.isEmpty && wa == words(b)
    }

    /// Heuristic: `text` starts a new utterance rather than revising `previous`.
    static func isNewUtterance(_ text: String, after previous: String) -> Bool {
        let new = words(text), old = words(previous)
        guard let firstNew = new.first, let firstOld = old.first, old.count >= 3 else { return false }
        return firstNew != firstOld && new.count * 2 < old.count
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
