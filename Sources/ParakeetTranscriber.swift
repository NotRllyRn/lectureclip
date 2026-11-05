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
        let samples = try AudioWindowReader.samples(snapshot: snapshot, start: start, end: end)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        guard let timings = result.tokenTimings else { throw ASRError.processingFailed("Recognition returned no timestamps.") }
        return buildWordTimings(from: timings).map {
            TranscriptWord(text: $0.word, start: start + $0.startTime, end: min(end, start + $0.endTime))
        }
    }
}

struct TranscriptionProgressError: LocalizedError {
    var errorDescription: String? { "Recognition did not advance through the saved audio. Audio is preserved." }
}
