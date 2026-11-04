import XCTest
@testable import LectureClip

@MainActor
final class LectureMetadataTests: XCTestCase {
    func testLegacySessionAndManualNameSurviveGeneratedNotes() throws {
        let old = """
        {"id":"00000000-0000-0000-0000-000000000005","createdAt":100,"timeline":{"words":[],"finalizedThrough":0,"quickExportCursor":0}}
        """
        var session = try JSONDecoder().decode(LectureSession.self, from: Data(old.utf8))
        let date = session.createdAt
        XCTAssertEqual(session.displayTitle, "Untitled lecture")
        session.rename("  Biology 101  ")
        session.applyNotes(title: "AI title", summary: "Opening notes", through: 120)
        let restored = try JSONDecoder().decode(LectureSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.title, "Biology 101")
        XCTAssertEqual(restored.createdAt, date)
        XCTAssertEqual(restored.summaryThrough, 120)
        XCTAssertEqual(restored.summary, "Opening notes")
    }

    func testAutomaticNotesWaitForTwoMinutesThenRefreshAfterCatchup() {
        var session = LectureSession(id: UUID(), createdAt: Date())
        session.timeline.finalizedThrough = 119
        XCTAssertNil(session.automaticNotesStage(isRecording: true, recordedThrough: 125))
        session.timeline.finalizedThrough = 120
        XCTAssertEqual(session.automaticNotesStage(isRecording: true, recordedThrough: 125), .opening)
        session.applyNotes(title: "Opening topic", summary: "Notes", through: 120)
        session.timeline.finalizedThrough = 240
        XCTAssertNil(session.automaticNotesStage(isRecording: true, recordedThrough: 245))
        XCTAssertNil(session.automaticNotesStage(isRecording: false, recordedThrough: 245))
        XCTAssertEqual(session.automaticNotesStage(isRecording: false, recordedThrough: 240), .complete)
        session.applyNotes(title: nil, summary: "Complete notes", through: 240)
        XCTAssertNil(session.automaticNotesStage(isRecording: false, recordedThrough: 240))
        var short = LectureSession(id: UUID(), createdAt: Date())
        short.timeline.finalizedThrough = 10
        XCTAssertEqual(short.automaticNotesStage(isRecording: false, recordedThrough: 10), .complete)
    }

    func testNotesMergeWithRenameMadeDuringGeneration() async throws {
        let intelligence = StubIntelligence()
        let store = LectureStore(intelligence: intelligence, restore: false)
        var saved = try SessionStore.create()
        defer { try? FileManager.default.removeItem(at: SessionStore.directory(saved.id)) }
        saved.timeline.words = [TranscriptWord(text: "Biology", start: 0, end: 1)]
        saved.timeline.finalizedThrough = 120
        try SessionStore.save(saved)
        await store.open(saved)
        // Auto generation is disabled for this test until explicitly requested.
        intelligence.isAvailable = true
        intelligence.onTitle = { store.renameRecording("My chosen name") }
        await store.summarize()
        XCTAssertEqual(store.session?.title, "My chosen name")
        XCTAssertEqual(store.session?.summary, "A concise summary")
        XCTAssertEqual(store.session?.timeline.finalizedThrough, 120)
        XCTAssertEqual(store.sessions.first(where: { $0.id == saved.id })?.title, "My chosen name")
        let loaded = try SessionStore.list().first(where: { $0.id == saved.id })
        XCTAssertEqual(loaded?.title, "My chosen name")
    }

    func testClipRetitlePreservesAudioAndRebasesPersistedPaths() throws {
        var session = try SessionStore.create()
        defer { try? FileManager.default.removeItem(at: SessionStore.directory(session.id)) }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let clip = ExportedClip(audioURL: folder.appendingPathComponent(name + ".m4a"),
                                transcriptURL: folder.appendingPathComponent(name + ".txt"), text: "Biology", start: 0, end: 1)
        try Data([1, 2, 3]).write(to: clip.audioURL)
        try Data("Biology".utf8).write(to: clip.transcriptURL)
        defer { ClipExporter.removeFiles(clip) }
        let renamed = try ClipExporter.retitled(clip, title: "Cell / biology: intro")
        defer { ClipExporter.removeFiles(renamed) }
        XCTAssertEqual(renamed.id, clip.id)
        XCTAssertEqual(try Data(contentsOf: renamed.audioURL), Data([1, 2, 3]))
        XCTAssertEqual(renamed.audioURL.deletingLastPathComponent(), folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.audioURL.path))
        var stale = renamed
        stale.audioURL = URL(fileURLWithPath: "/old-container/Exports/" + renamed.audioURL.lastPathComponent)
        session.clips = [stale]
        try SessionStore.save(session)
        let restored = try XCTUnwrap(SessionStore.list().first(where: { $0.id == session.id })?.clips?.first)
        XCTAssertEqual(restored.audioURL, renamed.audioURL)
        XCTAssertEqual(restored.title, "Cell / biology: intro")
    }
}

@MainActor
private final class StubIntelligence: LectureIntelligence {
    var isAvailable = false
    var onTitle: (() -> Void)?
    func title(for text: String) async throws -> String { onTitle?(); return "Generated title" }
    func summary(for text: String) async throws -> String { "A concise summary" }
}
