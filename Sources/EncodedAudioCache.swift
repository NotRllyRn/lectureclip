import AVFoundation
import Darwin
import Foundation

/// One continuous AAC encoder avoids priming/padding at every PCM chunk boundary.
/// Disposable acceleration only: PCM and chunks.json remain authoritative.
enum EncodedAudioCache {
    private static let queue = DispatchQueue(label: "lecture.audio.encode", qos: .utility)
    private static let slots = DispatchSemaphore(value: 2)
    private static let cache = Cache()
    private static func acquireSlot() -> Bool { slots.wait(timeout: .now()) == .success }

    static func schedule(_ chunks: [AudioChunk]) {
        guard !chunks.isEmpty, acquireSlot() else { return }
        queue.async {
            defer { slots.signal() }
            // A later snapshot includes skipped chunks, so capture never waits.
            _ = try? cache.update(chunks, cancellation: nil)
        }
    }

    static func discard(directory: URL) {
        queue.async { if cache.directory == directory { cache.encoder = nil } }
    }

    /// Returns an immutable snapshot. The caller owns and must remove it.
    static func prepare(_ chunks: [AudioChunk], finalize: Bool, reuse: Bool = true) async throws -> URL {
        try Task.checkCancellation()
        while !acquireSlot() { try await Task.sleep(for: .milliseconds(20)) }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    defer { slots.signal() }
                    do {
                        let shared = cache // Clean stale snapshots before creating a one-off encoder.
                        let encoder: Encoder
                        if reuse { encoder = try shared.update(chunks, cancellation: cancellation) }
                        else {
                            encoder = try Encoder()
                            for chunk in chunks { try encoder.append(chunk, cancellation: cancellation) }
                        }
                        if finalize { try encoder.finish(cancellation: cancellation) }
                        try cancellation.check()
                        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-aac-snapshot-\(UUID()).mov")
                        do {
                            // APFS clone snapshots the growing file without copying
                            // hours of bytes or observing writes halfway through a copy.
                            if clonefile(encoder.url.path, snapshot.path, 0) != 0 {
                                try FileManager.default.copyItem(at: encoder.url, to: snapshot)
                            }
                            try cancellation.check()
                            continuation.resume(returning: snapshot)
                        } catch {
                            try? FileManager.default.removeItem(at: snapshot)
                            throw error
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    // All mutable encoder state is confined to queue, including destruction.
    private final class Cache: @unchecked Sendable {
        var encoder: Encoder?
        var directory: URL?

        init() {
            // Disposable files from an interrupted prior process must not accumulate.
            for url in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
                where url.lastPathComponent.hasPrefix("lecture-aac-cache-") || url.lastPathComponent.hasPrefix("lecture-aac-snapshot-") {
                try? FileManager.default.removeItem(at: url)
            }
        }

        func update(_ chunks: [AudioChunk], cancellation: Cancellation?) throws -> Encoder {
            guard !chunks.isEmpty else { throw ClipError.invalidRange }
            let ids = chunks.map(\.id)
            if let current = encoder,
               current.ids.prefix(min(ids.count, current.ids.count)) != ids.prefix(min(ids.count, current.ids.count)) ||
                (current.writer.status == .completed && ids.count > current.ids.count) ||
                current.writer.status == .failed || current.writer.status == .cancelled {
                encoder = nil
            }
            do {
                if encoder == nil {
                    encoder = try Encoder()
                    directory = chunks.first?.url.deletingLastPathComponent()
                }
                let current = encoder!
                for chunk in chunks.dropFirst(current.ids.count) {
                    try cancellation?.check()
                    guard abs(chunk.start - current.duration) < 0.001 else { throw ClipError.missingAudio(at: current.duration) }
                    try current.append(chunk, cancellation: cancellation)
                    current.ids.append(chunk.id)
                    current.duration = chunk.end
                }
                return current
            } catch {
                encoder = nil // Never reuse a partially appended or failed encoder.
                throw error
            }
        }
    }

    private final class Encoder {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let format: AVAudioFormat
        var ids: [UUID] = []
        var duration = 0.0
        var frames: Int64 = 0

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-aac-cache-\(UUID()).mov")
            format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Completed fragments can be copied/read while capture continues.
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 48_000)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant
            ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }

        deinit {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
        }

        func append(_ chunk: AudioChunk, cancellation: Cancellation?) throws {
            let source = try AVAudioFile(forReading: chunk.url)
            guard source.length == chunk.frameCount, abs(source.processingFormat.sampleRate - chunk.sampleRate) < 0.01 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let target = Int64((chunk.end * 48_000).rounded())
            let expected = target - frames
            var converted: Int64 = 0
            var lastSample: Float = 0
            guard let converter = AVAudioConverter(from: source.processingFormat, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            converter.downmix = true
            let sourceInput = try ConversionInput(source: source)
            while true {
                try cancellation?.check()
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { count, state in
                    do {
                        let remaining = sourceInput.source.length - sourceInput.source.framePosition
                        guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                        try sourceInput.source.read(into: sourceInput.buffer, frameCount: min(count, sourceInput.buffer.frameCapacity, AVAudioFrameCount(clamping: remaining)))
                        state.pointee = sourceInput.buffer.frameLength == 0 ? .endOfStream : .haveData
                        return sourceInput.buffer.frameLength == 0 ? nil : sourceInput.buffer
                    } catch {
                        sourceInput.error = error
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let error = sourceInput.error ?? conversionError { throw error }
                if status == .error { throw CocoaError(.fileReadCorruptFile) }
                if output.frameLength > 0 {
                    converted += Int64(output.frameLength)
                    lastSample = output.floatChannelData![0][Int(output.frameLength) - 1]
                    output.frameLength = min(output.frameLength, AVAudioFrameCount(clamping: target - frames))
                    if output.frameLength > 0 { try append(output, cancellation: cancellation) }
                }
                if status == .endOfStream { break }
            }
            // Resampling may round by a few frames. Anchor each boundary to the
            // absolute recording clock instead of accumulating that error for hours.
            guard abs(converted - expected) <= 16 else { throw CocoaError(.fileReadCorruptFile) }
            if frames < target {
                output.frameLength = AVAudioFrameCount(target - frames)
                output.floatChannelData![0].update(repeating: lastSample, count: Int(output.frameLength))
                try append(output, cancellation: cancellation)
            }
        }

        func append(_ pcm: AVAudioPCMBuffer, cancellation: Cancellation?) throws {
            var description: CMAudioFormatDescription?
            try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description))
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: frames, timescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            try check(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength),
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample))
            guard let sample else { throw CocoaError(.fileWriteUnknown) }
            try check(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList))
            try check(CMSampleBufferSetDataReady(sample))
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                try cancellation?.check()
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            frames += Int64(pcm.frameLength)
        }

        func finish(cancellation: Cancellation) throws {
            if writer.status == .completed { return }
            input.markAsFinished()
            let completed = DispatchSemaphore(value: 0)
            writer.finishWriting { completed.signal() }
            let deadline = Date().addingTimeInterval(30)
            while completed.wait(timeout: .now() + 0.02) != .success {
                do { try cancellation.check() }
                catch { writer.cancelWriting(); throw error }
                guard Date() < deadline else { writer.cancelWriting(); throw CocoaError(.fileWriteUnknown) }
            }
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }

        private func check(_ status: OSStatus) throws {
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
    }

    /// AVAudioConverter invokes this input block synchronously on our serial queue.
    private final class ConversionInput: @unchecked Sendable {
        let source: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?
        init(source: AVAudioFile) throws {
            self.source = source
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192) else { throw CocoaError(.fileReadCorruptFile) }
            self.buffer = buffer
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }
}
