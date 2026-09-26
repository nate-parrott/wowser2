import XCTest
@testable import Core

/// Utterance merging for dictation (`TranscriptAccumulator`) and the cleanup
/// echo guard (`DictationCleanup.EchoStripper`). These are the two places
/// dictated text used to get duplicated or dropped.
final class DictationTranscriptTests: XCTestCase {

    // MARK: - Recognizer resets per utterance (on-device behavior)

    func testUtterancesAreJoinedWhenRecognizerResets() {
        var acc = TranscriptAccumulator()
        acc.absorb("Hello", finalizesUtterance: false)
        acc.absorb("Hello there", finalizesUtterance: false)
        acc.absorb("Hello there.", finalizesUtterance: true)
        // New utterance: recognizer no longer reports the old words.
        acc.absorb("How", finalizesUtterance: false)
        acc.absorb("How are you", finalizesUtterance: false)
        XCTAssertEqual(acc.transcript, "Hello there. How are you")
        acc.absorb("How are you?", finalizesUtterance: true)
        XCTAssertEqual(acc.transcript, "Hello there. How are you?")
    }

    func testFinalRepeatOfLastUtteranceIsNotDoubled() {
        var acc = TranscriptAccumulator()
        acc.absorb("Buy milk", finalizesUtterance: false)
        acc.absorb("Buy milk.", finalizesUtterance: true)
        // endAudio → isFinal result re-reports the same utterance.
        acc.absorb("Buy milk.", finalizesUtterance: true)
        XCTAssertEqual(acc.transcript, "Buy milk.")
    }

    func testNewUtteranceWithoutBoundaryMarkerIsKept() {
        var acc = TranscriptAccumulator()
        acc.absorb("The quick brown fox jumps", finalizesUtterance: false)
        // No metadata arrived, but the text restarted.
        acc.absorb("Over", finalizesUtterance: false)
        acc.absorb("Over the lazy dog", finalizesUtterance: false)
        XCTAssertEqual(acc.transcript, "The quick brown fox jumps Over the lazy dog")
    }

    func testPartialRevisionsReplaceRatherThanAppend() {
        var acc = TranscriptAccumulator()
        acc.absorb("I scream", finalizesUtterance: false)
        acc.absorb("Ice cream", finalizesUtterance: false)
        acc.absorb("Ice cream is great", finalizesUtterance: false)
        XCTAssertEqual(acc.transcript, "Ice cream is great")
    }

    // MARK: - Recognizer reports cumulatively

    func testCumulativeResultsAreNotDuplicated() {
        var acc = TranscriptAccumulator()
        acc.absorb("Hello there.", finalizesUtterance: true)
        acc.absorb("Hello there. How", finalizesUtterance: false)
        acc.absorb("Hello there. How are you?", finalizesUtterance: true)
        XCTAssertEqual(acc.transcript, "Hello there. How are you?")
        acc.absorb("Hello there. How are you? Fine", finalizesUtterance: false)
        XCTAssertEqual(acc.transcript, "Hello there. How are you? Fine")
        // Full cumulative final at the end adds nothing new.
        acc.absorb("Hello there. How are you? Fine", finalizesUtterance: true)
        acc.absorb("Hello there. How are you? Fine", finalizesUtterance: true)
        XCTAssertEqual(acc.transcript, "Hello there. How are you? Fine")
    }

    func testDropLeadingWords() {
        XCTAssertEqual(TranscriptAccumulator.dropLeadingWords("Hello there. How are you?", count: 2), "How are you?")
        XCTAssertEqual(TranscriptAccumulator.dropLeadingWords("Hello there.", count: 2), "")
        XCTAssertEqual(TranscriptAccumulator.dropLeadingWords("One", count: 0), "One")
    }

    // MARK: - Cleanup echo

    func testEchoOfFieldTextIsStripped() {
        var s = DictationCleanup.EchoStripper(fieldText: "Dear team, thanks for the update.")
        XCTAssertNil(s.strip("Dear team,"))
        XCTAssertNil(s.strip("Dear team, thanks for the"))
        XCTAssertEqual(s.strip("Dear team, thanks for the update."), "")
        XCTAssertEqual(s.strip("Dear team, thanks for the update. I'll"), "I'll")
        XCTAssertEqual(s.strip("Dear team, thanks for the update. I'll review it."), "I'll review it.")
    }

    func testNonEchoPassesThrough() {
        var s = DictationCleanup.EchoStripper(fieldText: "Dear team, thanks for the update.")
        XCTAssertEqual(s.strip("Sounds"), "Sounds")
        XCTAssertEqual(s.strip("Sounds good"), "Sounds good")
    }

    func testShortFieldTextIsNeverTreatedAsEcho() {
        var s = DictationCleanup.EchoStripper(fieldText: "Hi")
        XCTAssertEqual(s.strip("Hi there"), "Hi there")
    }
}
