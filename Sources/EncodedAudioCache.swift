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
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try encode(chunk)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    @discardableResult
    private static func encode(_ chunk: AudioChunk) throws -> URL {
        let destination = url(for: chunk)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("encode-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try AVAudioFile(forReading: chunk.url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Keep memory bounded even if a legacy source contains an unusually long chunk.
        var writer: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        while true {
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { count, state in
                do {
                    try source.read(into: input, frameCount: min(count, input.frameCapacity))
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
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
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
