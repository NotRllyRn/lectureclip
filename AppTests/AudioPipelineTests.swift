import AVFoundation
import XCTest
@testable import LectureClip

final class AudioPipelineTests: XCTestCase {
    @MainActor
    func testNativeRateWindowsReadAllFramesAcrossChunkBoundaries() async throws {
        for rate in [48_000.0, 44_100.0] {
            let session = try SessionStore.create()
            defer { try? FileManager.default.removeItem(at: SessionStore.directory(session.id)) }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let writer = ChunkWriter(format: format, directory: SessionStore.directory(session.id)) { message in
                XCTFail(message)
            }
            for _ in 0..<3 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_256))
                buffer.frameLength = 96_256
                for channel in 0..<2 {
                    let data = try XCTUnwrap(buffer.floatChannelData?[channel])
                    for frame in 0..<96_256 { data[frame] = Float(frame % 1000) / 2000 }
                }
                writer.enqueue(buffer)
                _ = try await writer.snapshot()
            }
            let snapshot = try SessionStore.snapshot(session.id)
            let chunk = try XCTUnwrap(snapshot.chunks.first)
            let file = try AVAudioFile(forReading: chunk.url)
            // AVAudioFile can return 95,232 frames for this 95,488-frame request.
            // Verify every sample, including the tail and a nonzero seek offset.
            for first in [Int64(0), 137] {
                let read = try AudioWindowReader.read(file, first: first, count: 95_488)
                XCTAssertEqual(read.frameLength, 95_488)
                for channel in 0..<2 {
                    let data = try XCTUnwrap(read.floatChannelData?[channel])
                    for frame in 0..<95_488 {
                        XCTAssertEqual(data[frame], Float((frame + Int(first)) % 1000) / 2000)
                    }
                }
            }
            for start in [0.0, 1.234567] {
                let samples = try AudioWindowReader.samples(snapshot: snapshot, start: start, end: 6)
                XCTAssertEqual(Double(samples.count), (6 - start) * 16_000, accuracy: 6)
                XCTAssertGreaterThan(samples.map { abs($0) }.reduce(0, +) / Float(samples.count), 0.1)
            }
            let gap = AudioSnapshot(chunks: Array(snapshot.chunks.dropFirst()), duration: snapshot.duration)
            XCTAssertThrowsError(try AudioWindowReader.samples(snapshot: gap, start: 0, end: 6))
            let truncated = AudioSnapshot(chunks: [AudioChunk(id: chunk.id, url: chunk.url, startFrame: 0,
                frameCount: chunk.frameCount + 1000, sampleRate: rate)], duration: chunk.end + 1000 / rate)
            XCTAssertThrowsError(try AudioWindowReader.samples(snapshot: truncated, start: 0, end: truncated.duration))
        }
    }

    @MainActor
    func testRecordingTapAcceptsBackgroundAudioWithSpareCapacity() async throws {
        for interleaved in [false, true] {
            let session = try SessionStore.create()
            defer { try? FileManager.default.removeItem(at: SessionStore.directory(session.id)) }
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                    channels: 2, interleaved: interleaved))
            let writer = ChunkWriter(format: format, directory: SessionStore.directory(session.id)) { _ in }
            let tap = writer.makeAudioTap()
            try await Task.detached {
                XCTAssertFalse(Thread.isMainThread)
                let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                             channels: 2, interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_000))
                buffer.frameLength = 800
                for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    let data = try XCTUnwrap(audio.mData).assumingMemoryBound(to: Float.self)
                    data.update(repeating: 0.25, count: Int(audio.mDataByteSize) / MemoryLayout<Float>.size)
                }
                tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            }.value
            let snapshot = try await writer.snapshot()
            XCTAssertEqual(snapshot.duration, 0.05, accuracy: 0.0001)
            let chunk = try XCTUnwrap(snapshot.chunks.first)
            let file = try AVAudioFile(forReading: chunk.url)
            XCTAssertEqual(file.length, 800)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800))
            try file.read(into: output)
            XCTAssertEqual(output.floatChannelData?[0][799], 0.25)
            XCTAssertEqual(output.floatChannelData?[1][799], 0.25)
        }
    }

    @MainActor
    func testAACCacheAndPassthroughAcrossPartialChunks() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        var chunks: [AudioChunk] = []
        // Different source rates must still produce compatible AAC segments.
        for (index, rate) in [16_000.0, 44_100.0, 48_000.0].enumerated() {
            let url = directory.appendingPathComponent("test-\(index).caf")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = 0.2 * sin(Float(Double(frame) * 2 * .pi * 440 / rate))
            }
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
            try file?.write(from: buffer)
            file = nil
            chunks.append(AudioChunk(id: UUID(), url: url, startFrame: Int64(Double(index) * 2 * rate),
                                     frameCount: Int64(rate * 2), sampleRate: rate))
        }
        for chunk in chunks {
            let url = try await EncodedAudioCache.prepare(chunk)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertEqual(Double(file.length) / 48_000, 2, accuracy: 0.05)
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let bitrate = try await track.load(.estimatedDataRate)
            XCTAssertEqual(bitrate, 64_000, accuracy: 16_000)
            let original = try Data(contentsOf: url)
            let reused = try await EncodedAudioCache.prepare(chunk)
            XCTAssertEqual(try Data(contentsOf: reused), original)
            try FileManager.default.removeItem(at: url)
            let regenerated = try await EncodedAudioCache.prepare(chunk)
            XCTAssertTrue(FileManager.default.fileExists(atPath: regenerated.path))
        }
        let output = directory.appendingPathComponent("passthrough.m4a")
        // Call the fast path directly: a PCM fallback must not mask failures.
        try await ClipExporter.exportCached(start: 0.37, end: 5.61, chunks: chunks, to: output)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 5.24, accuracy: 0.05)
        let decoded = try AVAudioFile(forReading: output)
        let audio = try AudioWindowReader.read(decoded, first: 0, count: AVAudioFrameCount(decoded.length))
        let samples = try XCTUnwrap(audio.floatChannelData?[0])
        // Check every short window, including joins, for unintended silent gaps.
        for first in stride(from: 480, to: Int(audio.frameLength) - 480, by: 480) {
            let energy = (first..<(first + 480)).reduce(Float(0)) { $0 + abs(samples[$1]) } / 480
            XCTAssertGreaterThan(energy, 0.03, "Unexpected silence at frame \(first)")
        }
        do {
            try await ClipExporter.exportCached(start: 0, end: 6, chunks: [chunks[0], chunks[2]],
                                                to: directory.appendingPathComponent("gap.m4a"))
            XCTFail("Missing audio must fail passthrough.")
        } catch ClipError.missingAudio(let time) { XCTAssertEqual(time, 2, accuracy: 0.001) }
        // A damaged disposable cache must not prevent exporting authoritative PCM.
        try Data("damaged cache".utf8).write(to: EncodedAudioCache.url(for: chunks[0]), options: .atomic)
        let fallback = try await ClipExporter.export(start: 0.37, end: 1.61, words: [], chunks: chunks)
        defer { ClipExporter.removeFiles(fallback) }
        let fallbackDuration = try await AVURLAsset(url: fallback.audioURL).load(.duration)
        XCTAssertEqual(fallbackDuration.seconds, 1.24, accuracy: 0.05)
    }

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
