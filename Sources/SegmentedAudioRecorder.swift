import AVFoundation
import Combine
import Foundation

private struct CaptureFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
final class SegmentedAudioRecorder: ObservableObject, LectureRecording {
    @Published private(set) var isRecording = false
    var onInterruption: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private var observers: [NSObjectProtocol] = []
    private var configurationObserver: NSObjectProtocol?

    init() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onInterruption?("Recording interrupted by an audio session or input change. Use Continue recording when the microphone is available.")
                }
            })
        }
    }

    func start(directory: URL, existing: AudioSnapshot = AudioSnapshot(chunks: [], duration: 0)) async throws {
        guard !isRecording else { return }
        try await Task.detached { try Self.validate(existing) }.value
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ClipError.microphoneDenied }
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        do {
            let newEngine = AVAudioEngine()
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureFailure(errorDescription: "No microphone input is available.")
            }
            let newWriter = ChunkWriter(format: format, directory: directory, existing: existing) { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onInterruption?(message)
                }
            }
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.2),
                             format: format, block: newWriter.makeAudioTap())
            do { try newEngine.start() }
            catch { input.removeTap(onBus: 0); throw error }
            engine = newEngine
            writer = newWriter
            isRecording = true
            // Register after startup; initial engine configuration is not an interruption.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onInterruption?("Audio input changed. Saved audio is preserved; use Continue recording when the microphone is available.")
                }
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    nonisolated static func validate(_ snapshot: AudioSnapshot) throws {
        guard snapshot.duration.isFinite, snapshot.duration >= 0 else { throw ClipError.invalidRange }
        var cursor = 0.0
        for chunk in snapshot.chunks {
            guard chunk.sampleRate.isFinite, chunk.sampleRate > 0, chunk.frameCount > 0,
                  abs(chunk.start - cursor) < 0.001 else { throw ClipError.missingAudio(at: cursor) }
            let file = try AVAudioFile(forReading: chunk.url)
            guard file.length >= chunk.frameCount, abs(file.processingFormat.sampleRate - chunk.sampleRate) < 0.01 else {
                throw ClipError.missingAudio(at: chunk.start)
            }
            cursor = chunk.end
        }
        guard abs(cursor - snapshot.duration) < 0.001 else { throw ClipError.missingAudio(at: cursor) }
    }

    func snapshotForExport() async throws -> AudioSnapshot {
        guard let writer else { return AudioSnapshot(chunks: [], duration: 0) }
        return try await writer.snapshot()
    }

    func stop() async throws -> AudioSnapshot {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        defer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        return try await snapshotForExport()
    }
}
