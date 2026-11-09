import AVFoundation
import Foundation

/// Disposable export acceleration; PCM and chunks.json remain authoritative.
enum EncodedAudioCache {
    private static let queue = DispatchQueue(label: "lecture.audio.encode", qos: .utility)
    private static let slots = DispatchSemaphore(value: 2)

    static func url(for chunk: AudioChunk) -> URL {
        chunk.url.deletingPathExtension().appendingPathExtension("aac64-v1.m4a")
    }

    static func schedule(_ chunk: AudioChunk) {
        guard slots.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { slots.signal() }
            // Encoding failure must never stop capture; export can retry or use PCM.
            try? encode(chunk)
        }
    }

    static func prepare(_ chunk: AudioChunk) async throws -> URL {
        try Task.checkCancellation()
        // Capture never waits; exports wait cooperatively for the same bounded queue.
        while slots.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(20)) }
        let cancellation = Cancellation()
        let result: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    defer { slots.signal() }
                    do { continuation.resume(returning: try encode(chunk, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }

    @discardableResult
    private static func encode(_ chunk: AudioChunk, cancellation: Cancellation? = nil) throws -> URL {
        try cancellation?.check()
        let destination = url(for: chunk)
        if FileManager.default.fileExists(atPath: destination.path) {
            if let file = try? AVAudioFile(forReading: destination),
               file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
               abs(Double(file.length) / file.processingFormat.sampleRate - (chunk.end - chunk.start)) < 0.05 {
                return destination
            }
            try FileManager.default.removeItem(at: destination)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("encode-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try AVAudioFile(forReading: chunk.url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        converter.downmix = true
        let input = try ConversionInput(source: source)
        // Keep memory bounded even if a legacy source contains an unusually long chunk.
        var writer: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        while true {
            try cancellation?.check()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { count, state in
                do {
                    try input.source.read(into: input.buffer, frameCount: min(count, input.buffer.frameCapacity))
                    state.pointee = input.buffer.frameLength == 0 ? .endOfStream : .haveData
                    return input.buffer.frameLength == 0 ? nil : input.buffer
                } catch {
                    input.error = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let error = input.error { throw error }
            if let conversionError { throw conversionError }
            if status == .error { throw CocoaError(.fileReadCorruptFile) }
            if output.frameLength > 0 { try writer?.write(from: output) }
            if status == .endOfStream { break }
        }
        writer = nil // Finalize the container before publishing it to readers.
        let encoded = try AVAudioFile(forReading: temporary)
        guard abs(Double(encoded.length) / encoded.processingFormat.sampleRate - (chunk.end - chunk.start)) < 0.05 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        try cancellation?.check()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// AVAudioConverter calls its Sendable input block synchronously. This state is
    /// owned exclusively by one conversion on the serial encoding queue.
    private final class ConversionInput: @unchecked Sendable {
        let source: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?

        init(source: AVAudioFile) throws {
            self.source = source
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.buffer = buffer
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }
}
