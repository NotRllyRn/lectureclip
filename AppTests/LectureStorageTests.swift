import XCTest
@testable import LectureClip

@MainActor
final class LectureStorageTests: XCTestCase {
    func testMissingFilesAreIdempotentButOtherErrorsAreNotIgnored() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNoThrow(try LectureStorage.removeIfPresent(missing))
        XCTAssertTrue(try LectureStorage.files(in: missing).isEmpty)
        XCTAssertTrue(LectureStorage.isMissing(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(LectureStorage.isMissing(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(LectureStorage.isMissing(NSError(domain: NSPOSIXErrorDomain, code: 2)))
        XCTAssertFalse(LectureStorage.isMissing(CocoaError(.fileWriteNoPermission)))
    }

    func testStorageScanAndDeletionCanOverlapWithoutMissingFileFailure() async throws {
        let saved = try SessionStore.create()
        defer { try? FileManager.default.removeItem(at: SessionStore.directory(saved.id)) }
        for index in 0..<100 {
            try Data([1, 2, 3]).write(to: SessionStore.directory(saved.id).appendingPathComponent("audio-\(index).caf"))
        }
        async let scan = LectureStorageWorker.shared.report(sessions: [saved])
        async let deletion: Void = LectureStorageWorker.shared.delete(saved, keeping: [])
        _ = try await (scan, deletion)
        // Retrying a completed deletion is harmless even with stale metadata.
        try await LectureStorageWorker.shared.delete(saved, keeping: [])
        let after = try await LectureStorageWorker.shared.report(sessions: [saved])
        XCTAssertEqual(after.bytesBySession[saved.id], 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionStore.directory(saved.id).path))
    }

    func testSizesIncludeMetadataUnindexedAudioAndDeduplicatedClips() throws {
        var first = try SessionStore.create()
        let second = try SessionStore.create()
        let name = UUID().uuidString
        let audio = LectureStorage.exports.appendingPathComponent(name + ".m4a")
        let text = LectureStorage.exports.appendingPathComponent(name + ".txt")
        try FileManager.default.createDirectory(at: LectureStorage.exports, withIntermediateDirectories: true)
        defer {
            for id in [first.id, second.id] { try? FileManager.default.removeItem(at: SessionStore.directory(id)) }
            for url in [audio, text] { try? FileManager.default.removeItem(at: url) }
        }
        try Data(repeating: 1, count: 10_000).write(to: SessionStore.directory(first.id).appendingPathComponent("unindexed.caf"))
        try Data(repeating: 2, count: 400).write(to: audio)
        try Data(repeating: 3, count: 100).write(to: text)
        let clip = ExportedClip(audioURL: audio, transcriptURL: text, text: "Study notes", start: 0, end: 1)
        first.clips = [clip, clip] // Duplicate references must not double the bytes.
        first.summary = "A summary stored with the transcript."
        try SessionStore.save(first)
        let metadata = try Data(contentsOf: SessionStore.directory(first.id).appendingPathComponent("session.json")).count
        let before = try LectureStorage.report(sessions: [first, second])
        XCTAssertEqual(before.bytesBySession[first.id], Int64(metadata + 10_500))
        XCTAssertGreaterThan(before.bytesBySession[second.id] ?? 0, 0)
        try LectureStorage.delete(first, keeping: [second])
        let after = try LectureStorage.report(sessions: [second])
        XCTAssertEqual(before.totalBytes - after.totalBytes, before.bytesBySession[first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionStore.directory(first.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
        XCTAssertEqual(before.bytesBySession[second.id], after.bytesBySession[second.id])
    }

    func testDeletionRetainsSharedClipsAndNeverFollowsStoredAbsolutePaths() throws {
        var first = try SessionStore.create()
        var second = try SessionStore.create()
        let name = UUID().uuidString + ".m4a"
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let owned = LectureStorage.exports.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: LectureStorage.exports, withIntermediateDirectories: true)
        defer {
            for id in [first.id, second.id] { try? FileManager.default.removeItem(at: SessionStore.directory(id)) }
            for url in [outside, owned] { try? FileManager.default.removeItem(at: url) }
        }
        try Data([1, 2]).write(to: outside)
        try Data([3, 4]).write(to: owned)
        first.clips = [ExportedClip(audioURL: outside, transcriptURL: outside, text: "", start: 0, end: 1)]
        second.clips = first.clips
        try LectureStorage.delete(first, keeping: [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2]))
        try LectureStorage.delete(second, keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2]))
    }
}
