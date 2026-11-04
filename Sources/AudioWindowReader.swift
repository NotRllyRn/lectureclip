import AVFoundation
import FluidAudio

/// Reads sealed chunks only; short AVAudioFile reads do not imply missing audio.
enum AudioWindowReader {
    static func samples(snapshot: AudioSnapshot, start: Double, end: Double, sampleRate: Double = 16_000) throws -> [Float] {
        guard start >= 0, end > start else { throw ClipError.invalidRange }
        let converter = AudioConverter(sampleRate: sampleRate)
        var samples: [Float] = []
        var cursor = start
        for chunk in snapshot.chunks where chunk.end > start && chunk.start < end {
            let lower = max(start, chunk.start)
            let upper = min(end, chunk.end)
            guard lower <= cursor + 0.001 else { throw ClipError.missingAudio(at: cursor) }
            let file = try AVAudioFile(forReading: chunk.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let first = Int64(((lower - chunk.start) * chunk.sampleRate).rounded())
            let last = Int64(((upper - chunk.start) * chunk.sampleRate).rounded())
            guard abs(file.processingFormat.sampleRate - chunk.sampleRate) < 0.01,
                  first >= 0, last <= file.length else {
                throw AudioReadError(detail: "\(chunk.url.lastPathComponent): requested frames \(first)..<\(last), file has \(file.length) frames at \(file.processingFormat.sampleRate) Hz; index uses \(chunk.sampleRate) Hz.")
            }
            if last > first {
                samples += try converter.resampleBuffer(read(file, first: first, count: AVAudioFrameCount(last - first)))
            }
            cursor = upper
        }
        guard cursor >= end - 0.001 else { throw ClipError.missingAudio(at: cursor) }
        return samples
    }

    static func read(_ file: AVAudioFile, first: Int64, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let channels = output.floatChannelData else { throw ASRError.invalidAudioData }
        file.framePosition = first
        var filled: AVAudioFrameCount = 0
        while filled < count {
            guard let part = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count - filled) else {
                throw ASRError.invalidAudioData
            }
            try file.read(into: part, frameCount: count - filled)
            guard part.frameLength > 0, let source = part.floatChannelData else {
                throw AudioReadError(detail: "\(file.url.lastPathComponent): read stopped at frame \(first + Int64(filled)); expected \(count) frames from \(first), file length \(file.length).")
            }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                channels[channel].advanced(by: Int(filled)).update(from: source[channel], count: Int(part.frameLength))
            }
            filled += part.frameLength
        }
        output.frameLength = filled
        return output
    }
}

private struct AudioReadError: LocalizedError {
    let detail: String
    var errorDescription: String? { "Could not read saved audio. \(detail)" }
}
