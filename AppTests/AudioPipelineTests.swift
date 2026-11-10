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
    func testAACDownmixPreservesEitherStereoChannel() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        for activeChannel in 0..<2 {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_137))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for frame in 0..<Int(buffer.frameLength) {
                    samples[frame] = channel == activeChannel ? 0.3 * sin(Float(frame) * 2 * .pi * 440 / 48_000) : 0
                }
            }
            let url = directory.appendingPathComponent("stereo-\(activeChannel).caf")
            var source: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
            try source?.write(from: buffer)
            source = nil
            let chunk = AudioChunk(id: UUID(), url: url, startFrame: 0, frameCount: 48_137, sampleRate: 48_000)
            let encoded = directory.appendingPathComponent("stereo-\(activeChannel).m4a")
            try await ClipExporter.exportCached(start: 0, end: chunk.end, chunks: [chunk], to: encoded)
            let file = try AVAudioFile(forReading: encoded)
            let audio = try AudioWindowReader.read(file, first: 0, count: AVAudioFrameCount(file.length))
            let samples = try XCTUnwrap(audio.floatChannelData?[0])
            let energy = (0..<Int(audio.frameLength)).reduce(Float(0)) { $0 + abs(samples[$1]) } / Float(audio.frameLength)
            XCTAssertGreaterThan(energy, 0.03, "Lost stereo channel \(activeChannel)")
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
                samples[frame] = 0.2 * sin(Float(Double(frame) * 2 * .pi * Double(440 * (index + 1)) / rate))
            }
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
            try file?.write(from: buffer)
            file = nil
            chunks.append(AudioChunk(id: UUID(), url: url, startFrame: Int64(Double(index) * 2 * rate),
                                     frameCount: Int64(rate * 2), sampleRate: rate))
        }
        // A live, continuous writer can export flushed fragments without closing.
        EncodedAudioCache.schedule(chunks)
        try await Task.sleep(for: .seconds(1))
        let live = directory.appendingPathComponent("live.m4a")
        try await ClipExporter.exportCached(start: 0.37, end: 4.61, chunks: chunks, to: live, finalize: false)
        let liveDuration = try await AVURLAsset(url: live).load(.duration)
        XCTAssertEqual(liveDuration.seconds, 4.24, accuracy: 0.05)
        let liveFile = try AVAudioFile(forReading: live)
        let liveAudio = try AudioWindowReader.read(liveFile, first: 0, count: AVAudioFrameCount(liveFile.length))
        let liveSamples = try XCTUnwrap(liveAudio.floatChannelData?[0])
        for first in stride(from: 480, to: Int(liveAudio.frameLength) - 480, by: 480) {
            let energy = (first..<(first + 480)).reduce(Float(0)) { $0 + abs(liveSamples[$1]) } / 480
            XCTAssertGreaterThan(energy, 0.03, "Silent live join at frame \(first)")
        }
        do {
            let url = try await EncodedAudioCache.prepare(chunks, finalize: true)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 6, accuracy: 0.05)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
            XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(format.mSampleRate, 48_000)
            XCTAssertEqual(format.mChannelsPerFrame, 1)
            let bitrate = try await track.load(.estimatedDataRate)
            XCTAssertEqual(bitrate, 64_000, accuracy: 16_000)
            let original = try Data(contentsOf: url)
            let reused = try await EncodedAudioCache.prepare(chunks, finalize: true)
            XCTAssertEqual(try Data(contentsOf: reused), original)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.removeItem(at: reused)
            let regenerated = try await EncodedAudioCache.prepare(chunks, finalize: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: regenerated.path))
            try FileManager.default.removeItem(at: regenerated)
        }
        let output = directory.appendingPathComponent("passthrough.m4a")
        // Call the fast path directly: a PCM fallback must not mask failures.
        do { try await ClipExporter.exportCached(start: 0.37, end: 5.61, chunks: chunks, to: output) }
        catch { XCTFail("Multi-chunk passthrough failed: \(error)"); return }
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
        // Distinct frequencies identify the source segment at both ends and joins.
        // Allow one AAC packet (1024 frames) around an edit boundary.
        for time in [0.05, 1.55, 1.69, 3.55, 3.69, 5.15] {
            let first = Int(time * 48_000)
            let count = 2400
            var crossings = 0
            for frame in (first + 1)..<(first + count) {
                if samples[frame - 1] <= 0 && samples[frame] > 0 { crossings += 1 }
            }
            let expected = Double(440 * (Int((time + 0.37) / 2) + 1))
            XCTAssertEqual(Double(crossings) / 0.05, expected, accuracy: 40, "Wrong audio at \(time)s")
        }
        let tiny = directory.appendingPathComponent("tiny.m4a")
        do { try await ClipExporter.exportCached(start: 1.991, end: 2.016, chunks: chunks, to: tiny) }
        catch { XCTFail("Tiny passthrough failed: \(error)"); return }
        let tinyDuration = try await AVURLAsset(url: tiny).load(.duration)
        XCTAssertEqual(tinyDuration.seconds, 0.025, accuracy: 0.022)
        do {
            try await ClipExporter.exportCached(start: 0, end: 6, chunks: [chunks[0], chunks[2]],
                                                to: directory.appendingPathComponent("gap.m4a"))
            XCTFail("Missing audio must fail passthrough.")
        } catch ClipError.missingAudio(let time) { XCTAssertEqual(time, 2, accuracy: 0.001) }
        let fallback = try await ClipExporter.export(start: 0.37, end: 1.61, words: [], chunks: chunks)
        defer { ClipExporter.removeFiles(fallback) }
        let fallbackDuration = try await AVURLAsset(url: fallback.audioURL).load(.duration)
        XCTAssertEqual(fallbackDuration.seconds, 1.24, accuracy: 0.05)
    }

    @MainActor
    func testLiveTailFallbackAndFinalizedCacheResume() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        var chunks = [try toneChunk(directory: directory, start: 0, seconds: 2, rate: 16_000)]
        // No future samples exist to flush the final live fragment. Fast export
        // must reject missing coverage; public export must preserve the entire tail.
        do {
            try await ClipExporter.exportCached(start: 0, end: 2, chunks: chunks,
                to: directory.appendingPathComponent("unavailable.m4a"), finalize: false)
            XCTFail("An unflushed tail must not be silently truncated")
        } catch {}
        let fallback = try await ClipExporter.export(start: 0, end: 2, words: [], chunks: chunks, recordingActive: true)
        defer { ClipExporter.removeFiles(fallback) }
        let tracks = try await AVURLAsset(url: fallback.audioURL).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let bitrate = try await track.load(.estimatedDataRate)
        XCTAssertEqual(bitrate, 64_000, accuracy: 16_000)
        let decoded = try AVAudioFile(forReading: fallback.audioURL)
        XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(decoded.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 2, accuracy: 0.05)
        let finalized = try await EncodedAudioCache.prepare(chunks, finalize: true)
        try FileManager.default.removeItem(at: finalized)
        chunks.append(try toneChunk(directory: directory, start: 2, seconds: 2, rate: 44_100))
        let resumed = directory.appendingPathComponent("resumed.m4a")
        try await ClipExporter.exportCached(start: 0, end: 4, chunks: chunks, to: resumed)
        let file = try AVAudioFile(forReading: resumed)
        let audio = try AudioWindowReader.read(file, first: 0, count: AVAudioFrameCount(file.length))
        let samples = try XCTUnwrap(audio.floatChannelData?[0])
        XCTAssertEqual(Double(file.length) / 48_000, 4, accuracy: 0.05)
        for first in stride(from: 480, to: Int(audio.frameLength) - 480, by: 480) {
            XCTAssertGreaterThan((first..<(first + 480)).reduce(Float(0)) { $0 + abs(samples[$1]) } / 480, 0.03)
        }
    }

    @MainActor
    func testWarmLongExportAndCancellationRecovery() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunks = try (0..<24).map { try toneChunk(directory: directory, start: Double($0) * 5, seconds: 5, rate: 16_000) }
        let cancelled = Task { try await EncodedAudioCache.prepare(chunks, finalize: true) }
        cancelled.cancel()
        do {
            let unexpected = try await cancelled.value
            try? FileManager.default.removeItem(at: unexpected)
            XCTFail("Cancelled cache preparation should throw")
        } catch is CancellationError {}
        let coldStart = Date()
        let cache = try await EncodedAudioCache.prepare(chunks, finalize: true)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        try FileManager.default.removeItem(at: cache)
        let began = Date()
        let output = directory.appendingPathComponent("long.m4a")
        try await ClipExporter.exportCached(start: 0.37, end: 119.61, chunks: chunks, to: output)
        print("AAC benchmark: 120s pre-encode \(coldSeconds)s, warm 119.24s export \(Date().timeIntervalSince(began))s")
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 119.24, accuracy: 0.05)
        let file = try AVAudioFile(forReading: output)
        let audio = try AudioWindowReader.read(file, first: 0, count: AVAudioFrameCount(file.length))
        let samples = try XCTUnwrap(audio.floatChannelData?[0])
        for first in stride(from: 480, to: Int(audio.frameLength) - 480, by: 480) {
            XCTAssertGreaterThan((first..<(first + 480)).reduce(Float(0)) { $0 + abs(samples[$1]) } / 480, 0.03)
        }
    }

    private func toneChunk(directory: URL, start: Double, seconds: Double, rate: Double) throws -> AudioChunk {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0.2 * sin(Float(Double(frame) * 2 * .pi * 440 / rate)) }
        let url = directory.appendingPathComponent("tone-\(UUID()).caf")
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer)
        file = nil
        return AudioChunk(id: UUID(), url: url, startFrame: Int64((start * rate).rounded()),
                          frameCount: Int64(buffer.frameLength), sampleRate: rate)
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
