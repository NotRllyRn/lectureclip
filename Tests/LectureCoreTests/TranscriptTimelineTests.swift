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

    func testOverlapContextCannotPinCursorAtReportedLectureBoundary() {
        let cursor = 1825.8799999999999
        var timeline = TranscriptTimeline(words: [word("committed", cursor - 1, cursor)], finalizedThrough: cursor)
        timeline.merge([word("overlapping context", cursor - 0.4, cursor + 5),
                        word("new speech", cursor + 1, cursor + 2)], windowEnd: cursor + 6, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, cursor + 4)
        XCTAssertEqual(timeline.words.map(\.text), ["committed", "new speech"])
        XCTAssertTrue(timeline.words.allSatisfy(\.isFinal))
    }

    func testLongWordAtCursorCommitsWithoutSplittingOrRepeatingIt() {
        var timeline = TranscriptTimeline(finalizedThrough: 1825.88)
        let longWord = word("long timestamp", 1825.88, 1831)
        timeline.merge([longWord], windowEnd: 1831.88, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, 1831)
        XCTAssertTrue(timeline.words[0].isFinal)
        timeline.merge([longWord, word("next", 1832, 1833)], windowEnd: 1837, isLast: false)
        XCTAssertEqual(timeline.words.map(\.text), ["long timestamp", "next"])
        XCTAssertEqual(timeline.finalizedThrough, 1835)
    }

    func testOutOfWindowWordCannotStallProgress() {
        var timeline = TranscriptTimeline(finalizedThrough: 10)
        timeline.merge([word("invalid span", 10, 100)], windowEnd: 16, isLast: false)
        XCTAssertEqual(timeline.finalizedThrough, 14)
        XCTAssertTrue(timeline.words.isEmpty)
    }

    func testSavedStalledLectureCatchesUpWithoutResettingExportCursor() throws {
        let cursor = 1825.8799999999999
        let saved = TranscriptTimeline(finalizedThrough: cursor, quickExportCursor: cursor)
        var timeline = try JSONDecoder().decode(TranscriptTimeline.self, from: JSONEncoder().encode(saved))
        for _ in 0..<400 {
            let previous = timeline.finalizedThrough
            if previous >= 3113 { break }
            let end = min(previous + 6, 3113)
            timeline.merge([word("overlap", previous - 0.2, end)], windowEnd: end, isLast: end == 3113)
            XCTAssertGreaterThan(timeline.finalizedThrough, previous)
        }
        XCTAssertEqual(timeline.finalizedThrough, 3113)
        XCTAssertEqual(try timeline.quickRange(recordedThrough: 3113), cursor..<3113)
    }

    func testInvalidTimestampsAreExcluded() {
        var timeline = TranscriptTimeline()
        timeline.merge([word("bad", .nan, 1), word("backwards", 3, 2), word("valid", 1, 2)], windowEnd: 6, isLast: true)
        XCTAssertEqual(timeline.words.map(\.text), ["valid"])
    }
}
