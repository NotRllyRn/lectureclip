import AVFoundation
import Combine
import Foundation

/// Only this class touches the audio file writer's mutable state. Its state is
/// confined to `queue`, so a snapshot can't race an active file write.
private final class ChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lecture.audio.disk", qos: .userInitiated)
    private let format: AVAudioFormat
    private let directory: URL
    private let chunkFrames: Int64

    private var totalFrames: Int64 = 0
    private var currentStartFrame: Int64 = 0
    private var currentFrames: Int64 = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var finished: [AudioChunk] = []
    private var failure: Error?

    init(format: AVAudioFormat, directory: URL, chunkSeconds: TimeInterval = 5) throws {
        self.format = format
        self.directory = directory
        self.chunkFrames = max(1, Int64(format.sampleRate * chunkSeconds))
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    /// Called by the real-time tap: just enqueue an immutable buffer.
    /// File system I/O happens exclusively on a serial disk queue.
    func enqueue(_ buffer: AVReadOnlyAudioPCMBuffer) {
        queue.async { [self] in
            guard failure == nil else { return }
            do {
                if currentFile == nil { try openFile() }
                try currentFile?.write(from: buffer)
                let frames = Int64(buffer.frameLength)
                totalFrames += frames
                currentFrames += frames
                if currentFrames >= chunkFrames { sealCurrentFile() }
            } catch {
                failure = error
            }
        }
    }

    private func openFile() throws {
        let url = directory.appendingPathComponent(
            String(format: "chunk_%06d.caf", finished.count))
        currentURL = url
        currentStartFrame = totalFrames
        currentFrames = 0
        currentFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    private func sealCurrentFile() {
        guard let file = currentFile, let url = currentURL else { return }
        file.close()     // Update CAF header before any exporter reads it.
        if currentFrames > 0 {
            finished.append(AudioChunk(
                id: UUID(), url: url, startFrame: currentStartFrame,
                frameCount: currentFrames, sampleRate: format.sampleRate
            ))
        }
        currentFile = nil
        currentURL = nil
        currentFrames = 0
    }

    /// Called without stopping AVAudioEngine. Future buffers open the next chunk.
    func sealAndSnapshot() async throws -> AudioSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { continuation.resume(throwing: failure); return }
                sealCurrentFile()
                continuation.resume(returning: AudioSnapshot(
                    chunks: finished, duration: Double(totalFrames) / format.sampleRate
                ))
            }
        }
    }
}

@MainActor
final class SegmentedAudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private(set) var startedAt: Date?
    var displayElapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func start() async throws {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else { throw ClipError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Lecture_\(UUID().uuidString)",
                                                      isDirectory: true)
        let newWriter = try ChunkWriter(format: format, directory: folder)

        // iPadOS 27+: Apple's sendable, read-only audio buffer tap.
        try input.installAudioTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.2), format: format) {
            [newWriter] buffer, _ in
            newWriter.enqueue(buffer)
        }
        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = newEngine
        writer = newWriter
        isRecording = true
        startedAt = Date()
    }

    /// Finalizes the current file without stopping the microphone.
    func snapshotForExport() async throws -> AudioSnapshot {
        guard let writer else { return AudioSnapshot(chunks: [], duration: 0) }
        return try await writer.sealAndSnapshot()
    }

    @discardableResult
    func stop() async throws -> AudioSnapshot {
        guard isRecording else { return try await snapshotForExport() }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        let chunks = try await snapshotForExport()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        return chunks
    }
}
