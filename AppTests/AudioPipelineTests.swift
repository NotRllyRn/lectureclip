import AVFoundation
import XCTest
@testable import LectureClip

final class AudioPipelineTests: XCTestCase {
    @MainActor
    func testDurableChunksAndSelectedM4AExport() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = ChunkWriter(format: format, directory: directory) { _ in }
        for _ in 0..<6 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<16_000 { channel[frame] = 0.1 * sin(Float(frame) * 2 * .pi * 440 / 16_000) }
            writer.enqueue(buffer)
            _ = try await writer.snapshot()
        }
        // Reload from the persisted index, independent of the writer's memory.
        let restored = try SessionStore.snapshot(session.id)
        XCTAssertEqual(restored.duration, 6, accuracy: 0.001)
        XCTAssertEqual(restored.chunks.count, 6)
        let words = [TranscriptWord(text: "before", start: 0, end: 1),
                     TranscriptWord(text: "selected", start: 2, end: 2.5),
                     TranscriptWord(text: "after", start: 5, end: 6)]
        let clip = try await ClipExporter.export(start: 1.25, end: 4.75, words: words, chunks: restored.chunks)
        defer {
            try? FileManager.default.removeItem(at: clip.audioURL)
            try? FileManager.default.removeItem(at: clip.transcriptURL)
        }
        XCTAssertEqual(clip.text, "selected")
        XCTAssertTrue(try String(contentsOf: clip.transcriptURL, encoding: .utf8).contains("selected"))
        let duration = try await AVURLAsset(url: clip.audioURL).load(.duration)
        XCTAssertEqual(duration.seconds, 3.5, accuracy: 0.05)
        let decoded = try AVAudioFile(forReading: clip.audioURL)
        XCTAssertGreaterThan(decoded.length, 0)

        do {
            _ = try await ClipExporter.export(start: 0, end: 3, words: words,
                                               chunks: restored.chunks.filter { $0.start != 1 })
            XCTFail("An export with missing audio must fail rather than silently omit it.")
        } catch ClipError.missingAudio(let time) { XCTAssertEqual(time, 1, accuracy: 0.001) }
    }
}
