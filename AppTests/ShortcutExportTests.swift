import AVFoundation
import AppIntents
import XCTest
import UIKit
@testable import LectureClip

@MainActor
final class ShortcutExportTests: XCTestCase {
    func testFailedCopyKeepsCursorAndConcurrentExportsDoNotDuplicate() async throws {
        let saved = try await fixture()
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        defer {
            try? FileManager.default.removeItem(at: SessionStore.directory(saved.id))
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
        }
        let clipboard = ClipboardAcceptance()
        let store = LectureStore(intelligence: UnavailableIntelligence(), restore: false, copyClip: { _ in clipboard.acceptsCopy })
        await store.open(saved)
        let failed = await store.export(reportErrors: false)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 0)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.session?.clips?.isEmpty ?? true)

        clipboard.acceptsCopy = true
        async let first = store.export(reportErrors: false)
        async let second = store.export(reportErrors: false)
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let clip = try XCTUnwrap(store.lastClip)
        defer { ClipExporter.removeFiles(clip) }
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.end, 2)
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 2)
        XCTAssertEqual(store.session?.clips?.count, 1)
        let noNewAudio = await store.export(reportErrors: false)
        XCTAssertFalse(noNewAudio)
        let restored = LectureStore(intelligence: UnavailableIntelligence())
        XCTAssertEqual(restored.session?.id, saved.id)
        XCTAssertEqual(restored.session?.timeline.quickExportCursor, 2)
        XCTAssertFalse(restored.modelReady)
    }

    func testIntentReturnsBooleanAndCopiesRealAudio() async throws {
        let saved = try await fixture()
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        defer {
            try? FileManager.default.removeItem(at: SessionStore.directory(saved.id))
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
        }
        await LectureStore.shared.open(saved)
        let shared = LectureStore.shared
        XCTAssertEqual(shared.session?.id, saved.id, "busy=\(shared.isBusy), recording=\(shared.isRecording), notes=\(shared.summarizing), exporting=\(shared.exporting)")
        let result = try await QuickExportIntent().perform()
        XCTAssertEqual(result.value, true, "protected=\(UIApplication.shared.isProtectedDataAvailable), cursor=\(shared.session?.timeline.quickExportCursor ?? -1), duration=\(shared.snapshot.duration), diagnostics=\(UserDefaults.standard.stringArray(forKey: "recentDiagnostics")?.suffix(4).joined(separator: " | ") ?? "")")
        let clip = try XCTUnwrap(LectureStore.shared.lastClip)
        defer { ClipExporter.removeFiles(clip) }
        XCTAssertGreaterThan(try AVAudioFile(forReading: clip.audioURL).length, 0)
        XCTAssertEqual(clip.text, "Selected speech.")
        let repeated = try await QuickExportIntent().perform()
        XCTAssertEqual(repeated.value, false)
    }

    func testBackgroundFileExportBypassesClipboardAndReturnsFiles() async throws {
        let saved = try await fixture()
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        defer {
            try? FileManager.default.removeItem(at: SessionStore.directory(saved.id))
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
        }
        let store = LectureStore(intelligence: UnavailableIntelligence(), restore: false, copyClip: { _ in
            XCTFail("File handoff must not access the background clipboard")
            return false
        })
        await store.open(saved)
        let exported = await store.quickExportFilesFromShortcut()
        let clip = try XCTUnwrap(exported)
        defer { ClipExporter.removeFiles(clip) }
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 2)
        XCTAssertGreaterThan(try AVAudioFile(forReading: clip.audioURL).length, 0)
        XCTAssertTrue(try String(contentsOf: clip.transcriptURL, encoding: .utf8).contains("Selected speech."))
        let repeated = await store.quickExportFilesFromShortcut()
        XCTAssertNil(repeated)

        // Reset only this fixture's cursor and exercise the public file-valued intent.
        try SessionStore.save(saved)
        await LectureStore.shared.open(saved)
        let result = try await QuickExportFilesIntent().perform()
        let files = try XCTUnwrap(result.value)
        defer { if let clip = LectureStore.shared.lastClip { ClipExporter.removeFiles(clip) } }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first?.type, .mpeg4Audio)
        XCTAssertEqual(files.last?.type, .plainText)
        XCTAssertFalse(files[0].data.isEmpty)
        XCTAssertTrue(String(data: files[1].data, encoding: .utf8)?.contains("Selected speech.") == true)
        let empty = try await QuickExportFilesIntent().perform()
        XCTAssertEqual(empty.value?.count, 0)
    }

    private func fixture() async throws -> LectureSession {
        var session = try SessionStore.create()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = ChunkWriter(format: format, directory: SessionStore.directory(session.id)) { message in XCTFail(message) }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        buffer.frameLength = 64_000
        buffer.floatChannelData?[0].update(repeating: 0.1, count: 64_000)
        writer.enqueue(buffer)
        _ = try await writer.snapshot()
        session.timeline.words = [TranscriptWord(text: "Selected speech.", start: 0, end: 1),
                                  TranscriptWord(text: "Pending", start: 3, end: 4, isFinal: false)]
        session.timeline.finalizedThrough = 2
        try SessionStore.save(session)
        return session
    }
}

@MainActor
private struct UnavailableIntelligence: LectureIntelligence {
    var isAvailable: Bool { false }
    func title(for text: String) async throws -> String { XCTFail("Should not load language model"); return "" }
    func summary(for text: String) async throws -> String { XCTFail("Should not load language model"); return "" }
}

@MainActor
private final class ClipboardAcceptance { var acceptsCopy = false }
