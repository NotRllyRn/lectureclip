import AVFoundation
import Foundation

@MainActor
struct ClipExporter {
    /// Export any continuous time range using ONLY finalized chunks. Recording
    /// remains active in the recorder during this whole operation.
    static func export(start: TimeInterval, end: TimeInterval,
                       words: [TranscriptWord], chunks: [AudioChunk], title: String? = nil) async throws -> ExportedClip {
        guard start >= 0, end - start >= 0.025 else { throw ClipError.invalidRange }
        let outputDirectory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        let name = fileName(for: title ?? "Lecture clip")
        let audioURL = outputDirectory.appendingPathComponent(name + ".m4a")
        let transcriptURL = outputDirectory.appendingPathComponent(name + ".txt")
        let began = Date()
        do {
            try await exportCached(start: start, end: end, chunks: chunks, to: audioURL)
            Diagnostics.record("AAC passthrough export: \(end - start)s audio in \(Date().timeIntervalSince(began))s")
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            try Task.checkCancellation()
            Diagnostics.record("AAC export fallback: \(error.localizedDescription)")
            // Cache/codec failures must not make preserved PCM unexportable.
            do { try await exportPCM(start: start, end: end, chunks: chunks, to: audioURL) }
            catch {
                try? FileManager.default.removeItem(at: audioURL)
                throw error
            }
        }

        let excerpt = selectedWords(words, start: start, end: end)
        let transcriptText = excerpt.map(\.text).joined(separator: " ")
        let document = "Audio interval: \(clockString(start)) – \(clockString(end))\n" +
            "Transcript: \(transcriptText)\n"
        do {
            try document.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }
        return ExportedClip(title: title, audioURL: audioURL, transcriptURL: transcriptURL,
                            text: transcriptText, start: start, end: end)
    }

    static func exportCached(start: Double, end: Double, chunks: [AudioChunk], to url: URL) async throws {
        guard start >= 0, end - start >= 0.025 else { throw ClipError.invalidRange }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipError.cannotCreateComposition
        }
        var cursor = start
        for chunk in chunks.sorted(by: { $0.start < $1.start }) where chunk.end > start && chunk.start < end {
            let lower = max(cursor, chunk.start)
            let upper = min(end, chunk.end)
            guard lower <= cursor + 0.001 else { throw ClipError.missingAudio(at: cursor) }
            guard upper > lower else { continue }
            let asset = AVURLAsset(url: try await EncodedAudioCache.prepare(chunk))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ClipError.cannotCreateComposition
            }
            let range = CMTimeRange(start: CMTime(seconds: lower - chunk.start, preferredTimescale: 48_000),
                                    duration: CMTime(seconds: upper - lower, preferredTimescale: 48_000))
            try track.insertTimeRange(range, of: source, at: CMTime(seconds: lower - start, preferredTimescale: 48_000))
            cursor = upper
        }
        guard cursor >= end - 0.001 else { throw ClipError.missingAudio(at: cursor) }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipError.cannotCreateExportSession
        }
        try await session.export(to: url, as: .m4a)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard abs(duration - (end - start)) < 0.05 else { throw ClipError.cannotCreateComposition }
    }

    private static func exportPCM(start: Double, end: Double, chunks: [AudioChunk], to url: URL) async throws {
        let preparedURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: preparedURL) }
        let preparation = Task.detached(priority: .userInitiated) {
            try prepareAudio(start: start, end: end, chunks: chunks, to: preparedURL)
        }
        try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: preparedURL), presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipError.cannotCreateExportSession
        }
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: end - start, preferredTimescale: 48_000))
        try await session.export(to: url, as: .m4a)
    }

    /// Normalize bounded windows before encoding; mixed-rate composition edits are unreliable on iOS 26.
    nonisolated private static func prepareAudio(start: Double, end: Double, chunks: [AudioChunk], to url: URL) throws {
        // Avoid upsampling; retain the lowest native rate in the selected interval.
        let selected = chunks.filter { $0.end > start && $0.start < end }
        guard let rate = selected.map(\.sampleRate).min() else { throw ClipError.missingAudio(at: start) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw ClipError.cannotCreateComposition
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let ordered = selected.sorted { $0.start < $1.start }
        var chunkIndex = 0
        let total = Int64(((end - start) * rate).rounded())
        var written: Int64 = 0
        while written < total {
            try Task.checkCancellation()
            let count = Int(min(Int64(rate * 5), total - written))
            let lower = start + Double(written) / rate
            let upper = min(end, start + Double(written + Int64(count)) / rate)
            while chunkIndex < ordered.count && ordered[chunkIndex].end <= lower { chunkIndex += 1 }
            let window = ordered[chunkIndex...].prefix { $0.start < upper }
            let snapshot = AudioSnapshot(chunks: Array(window), duration: end)
            let samples = try AudioWindowReader.samples(snapshot: snapshot, start: lower, end: upper, sampleRate: rate)
            guard !samples.isEmpty, abs(samples.count - count) <= 4,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw ExportPreparationError(expected: count, actual: samples.count) }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: min(count, samples.count)) }
            // Resampling rounds by a few frames; anchor every window to the export sample clock.
            if samples.count < count {
                channel.advanced(by: samples.count).update(repeating: samples.last!, count: count - samples.count)
            }
            try file.write(from: buffer)
            written += Int64(count)
        }
    }

    private static func fileName(for title: String) -> String {
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(String((safe.isEmpty ? "Lecture clip" : safe).prefix(70)))-\(UUID().uuidString.prefix(8))"
    }

    /// Copy first so a failed session save can roll back without losing the original clip.
    static func retitled(_ clip: ExportedClip, title: String) throws -> ExportedClip {
        let name = fileName(for: title)
        var updated = clip
        updated.title = title
        updated.audioURL = clip.audioURL.deletingLastPathComponent().appendingPathComponent(name + ".m4a")
        updated.transcriptURL = clip.transcriptURL.deletingLastPathComponent().appendingPathComponent(name + ".txt")
        do {
            try FileManager.default.copyItem(at: clip.audioURL, to: updated.audioURL)
            try FileManager.default.copyItem(at: clip.transcriptURL, to: updated.transcriptURL)
            return updated
        } catch {
            removeFiles(updated)
            throw error
        }
    }

    static func removeFiles(_ clip: ExportedClip) {
        try? FileManager.default.removeItem(at: clip.audioURL)
        try? FileManager.default.removeItem(at: clip.transcriptURL)
    }

}

private struct ExportPreparationError: LocalizedError {
    let expected: Int
    let actual: Int
    var errorDescription: String? { "Audio conversion produced \(actual) frames; expected \(expected)." }
}
