import Foundation

struct TranscriptTimeline: Codable, Sendable {
    var words: [TranscriptWord] = []
    var finalizedThrough: TimeInterval = 0
    var quickExportCursor: TimeInterval = 0

    // Overlap is context only before the committed boundary. Keep a two-second
    // revisable tail, and move the boundary back if it would split a word.
    mutating func merge(_ incoming: [TranscriptWord], windowEnd: Double, isLast: Bool) {
        let oldBoundary = finalizedThrough
        let valid = incoming.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        var boundary = max(oldBoundary, isLast ? windowEnd : windowEnd - 2)
        if let crossing = valid.first(where: { $0.start < boundary && $0.end > boundary }) {
            boundary = max(oldBoundary, crossing.start)
        }
        words.removeAll { !$0.isFinal }
        let lastEnd = words.last?.end ?? oldBoundary
        words += valid.filter { $0.start >= oldBoundary && $0.start >= lastEnd && $0.end <= windowEnd }
            .map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end, isFinal: $0.end <= boundary) }
            .sorted { $0.start < $1.start }
        finalizedThrough = boundary
    }

    func quickRange(recordedThrough: Double) throws -> Range<Double> {
        let end = min(finalizedThrough, recordedThrough)
        guard end - quickExportCursor >= 0.025 else { throw ClipError.noNewAudio }
        return quickExportCursor..<end
    }
}
