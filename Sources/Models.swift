import Foundation

/// Times are seconds from audio sample zero. Real ASR must share this timeline.
struct TranscriptWord: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool

    init(text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}

struct AudioChunk: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let startFrame: Int64
    let frameCount: Int64
    let sampleRate: Double

    var start: TimeInterval { Double(startFrame) / sampleRate }
    var end: TimeInterval { Double(startFrame + frameCount) / sampleRate }
}

struct AudioSnapshot: Sendable {
    let chunks: [AudioChunk]
    let duration: TimeInterval
}

struct ExportedClip: Sendable {
    let audioURL: URL
    let transcriptURL: URL
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum ClipError: LocalizedError {
    case invalidRange
    case noNewAudio
    case missingAudio(at: TimeInterval)
    case noAudioTrack
    case cannotCreateComposition
    case cannotCreateExportSession
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .invalidRange: "The selected audio range is invalid."
        case .noNewAudio: "There is no new recorded audio to export yet."
        case .missingAudio(let t): "Recorded audio is missing near \(String(format: "%.2f", t)) seconds."
        case .noAudioTrack: "An audio chunk has no audio track."
        case .cannotCreateComposition: "Could not create the export composition."
        case .cannotCreateExportSession: "Could not create an M4A export session."
        case .microphoneDenied: "Microphone permission was denied."
        }
    }
}

func clockString(_ t: TimeInterval) -> String {
    let total = Int(max(0, t))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

/// Include words touching the requested interval. ASR must supply per-word
/// timestamps for word-accurate advanced selection.
func selectedWords(_ words: [TranscriptWord], start: TimeInterval,
                   end: TimeInterval) -> [TranscriptWord] {
    words.filter { $0.isFinal && $0.start < end && $0.end > start }
        .sorted { $0.start < $1.start }
}
