import AVFoundation
import FluidAudio
import Foundation

actor ParakeetTranscriber {
    private var manager: AsrManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        manager = AsrManager(models: models)
    }

    func transcribe(snapshot: AudioSnapshot, start: Double, end: Double) async throws -> [TranscriptWord] {
        guard let manager else { throw ASRError.notInitialized }
        // Read only the requested part of each sealed file, never a whole lecture.
        let converter = AudioConverter(sampleRate: 16_000)
        var samples: [Float] = []
        var cursor = start
        for chunk in snapshot.chunks where chunk.end > start && chunk.start < end {
            let lower = max(start, chunk.start)
            let upper = min(end, chunk.end)
            guard lower <= cursor + 0.001 else { throw ClipError.missingAudio(at: cursor) }
            let file = try AVAudioFile(forReading: chunk.url)
            file.framePosition = AVAudioFramePosition(((lower - chunk.start) * chunk.sampleRate).rounded())
            let count = AVAudioFrameCount(((upper - lower) * chunk.sampleRate).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw ASRError.invalidAudioData
            }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw ClipError.missingAudio(at: lower) }
            samples += try converter.resampleBuffer(buffer)
            cursor = upper
        }
        guard cursor >= end - 0.001 else { throw ClipError.missingAudio(at: cursor) }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        guard let timings = result.tokenTimings else { throw ASRError.processingFailed("Recognition returned no timestamps.") }
        return buildWordTimings(from: timings).map {
            TranscriptWord(text: $0.word, start: start + $0.startTime, end: min(end, start + $0.endTime))
        }
    }
}
