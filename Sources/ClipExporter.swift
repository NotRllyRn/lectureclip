import AVFoundation
import Foundation

@MainActor
struct ClipExporter {
    /// Export any continuous time range using ONLY finalized chunks. Recording
    /// remains active in the recorder during this whole operation.
    static func export(start: TimeInterval, end: TimeInterval,
                       words: [TranscriptWord], chunks: [AudioChunk], title: String? = nil) async throws -> ExportedClip {
        guard start >= 0, end - start >= 0.025 else { throw ClipError.invalidRange }
        let sorted = chunks.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { throw ClipError.missingAudio(at: start) }

        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ClipError.cannotCreateComposition }

        var cursor = start
        var insertionTime = CMTime.zero
        let tolerance = 0.0001
        for chunk in sorted {
            if cursor >= end - tolerance { break }
            let overlapStart = max(cursor, chunk.start)
            let overlapEnd = min(end, chunk.end)
            guard overlapEnd > overlapStart else { continue }
            if overlapStart > cursor + tolerance { throw ClipError.missingAudio(at: cursor) }

            let asset = AVURLAsset(url: chunk.url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ClipError.noAudioTrack
            }
            let range = CMTimeRange(
                start: CMTime(seconds: overlapStart - chunk.start, preferredTimescale: 60_000),
                duration: CMTime(seconds: overlapEnd - overlapStart, preferredTimescale: 60_000)
            )
            try outputTrack.insertTimeRange(range, of: track, at: insertionTime)
            insertionTime = CMTimeAdd(insertionTime, range.duration)
            cursor = overlapEnd
        }
        if cursor < end - tolerance { throw ClipError.missingAudio(at: cursor) }

        let outputDirectory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        let name = fileName(for: title ?? "Lecture clip")
        let audioURL = outputDirectory.appendingPathComponent(name + ".m4a")
        let transcriptURL = outputDirectory.appendingPathComponent(name + ".txt")
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else { throw ClipError.cannotCreateExportSession }
        // Bound encoding explicitly: mixed sample-rate edits can extend the inferred end.
        session.timeRange = CMTimeRange(start: .zero, duration: insertionTime)
        try await session.export(to: audioURL, as: .m4a)

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
