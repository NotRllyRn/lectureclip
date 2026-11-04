import XCTest
@testable import LectureCore

final class TranscriptTimelineTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    func testOverlapReplacesProvisionalWordsWithoutRepeatingCommittedWords() {
        var timeline = TranscriptTimeline()
        timeline.merge([word("Hello", 0, 1), word("wrong", 4.2, 5)], windowEnd: 6, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, 4)
        XCTAssertFalse(timeline.words[1].isFinal)
        timeline.merge([word("Hello", 0, 1), word("world", 4.2, 5), word("today", 6, 7)], windowEnd: 8, isLast: false)
        XCTAssertEqual(timeline.words.map(\.text), ["Hello", "world", "today"])
        XCTAssertTrue(timeline.words[1].isFinal)
        XCTAssertFalse(timeline.words[2].isFinal)
    }

    func testFinalBoundaryDoesNotSplitWord() {
        var timeline = TranscriptTimeline()
        timeline.merge([word("capacitor", 3.7, 4.4)], windowEnd: 6, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, 3.7)
        XCTAssertFalse(timeline.words[0].isFinal)
        timeline.merge([word("capacitor", 3.7, 4.4)], windowEnd: 7, isLast: true)
        XCTAssertTrue(timeline.words[0].isFinal)
        XCTAssertEqual(timeline.finalizedThrough, 7)
    }

    func testQuickExportStopsAtFinalizedCursorAndLeavesUntranscribedAudio() throws {
        var timeline = TranscriptTimeline()
        timeline.merge([], windowEnd: 10, isLast: false)
        let first = try timeline.quickRange(recordedThrough: 10)
        XCTAssertEqual(first, 0..<8)
        // Caller updates only after successful export and persistence.
        timeline.quickExportCursor = first.upperBound
        XCTAssertThrowsError(try timeline.quickRange(recordedThrough: 10))
        timeline.merge([], windowEnd: 10, isLast: true)
        XCTAssertEqual(try timeline.quickRange(recordedThrough: 10), 8..<10)
    }

    func testSilenceAdvancesAndFinalFlushCommitsTail() {
        var timeline = TranscriptTimeline()
        timeline.merge([], windowEnd: 6, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, 4)
        timeline.merge([word("end", 5, 5.9)], windowEnd: 6, isLast: true)
        XCTAssertEqual(timeline.finalizedThrough, 6)
        XCTAssertEqual(timeline.words.filter(\.isFinal).count, 1)
    }

    func testPersistenceRetainsProgressAndExportCursor() throws {
        var timeline = TranscriptTimeline()
        timeline.merge([word("saved", 1, 2)], windowEnd: 6, isLast: true)
        timeline.quickExportCursor = 3
        let restored = try JSONDecoder().decode(TranscriptTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(restored.words, timeline.words)
        XCTAssertEqual(restored.finalizedThrough, 6)
        XCTAssertEqual(try restored.quickRange(recordedThrough: 6), 3..<6)
    }

    func testAdjacentSelectionUsesHalfOpenIntervals() {
        let words = [word("first", 0, 1), word("second", 1, 2)]
        XCTAssertEqual(selectedWords(words, start: 0, end: 1).map(\.text), ["first"])
        XCTAssertEqual(selectedWords(words, start: 1, end: 2).map(\.text), ["second"])
    }

    func testInvalidTimestampsAreExcluded() {
        var timeline = TranscriptTimeline()
        timeline.merge([word("bad", .nan, 1), word("backwards", 3, 2), word("valid", 1, 2)], windowEnd: 6, isLast: true)
        XCTAssertEqual(timeline.words.map(\.text), ["valid"])
    }
}
