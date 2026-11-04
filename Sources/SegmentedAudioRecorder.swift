import AVFoundation
import Combine
import Foundation

private struct CaptureFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
final class SegmentedAudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    var onInterruption: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                     Notification.Name.AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onInterruption?("Recording interrupted by an audio session or input change. Start a new recording to continue.")
                }
            })
        }
    }

    func start(directory: URL) async throws {
        guard !isRecording else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw ClipError.microphoneDenied }
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
            let newWriter = ChunkWriter(format: format, directory: directory) { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onInterruption?(message)
                }
            }
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.2), format: format) { buffer, _ in
                newWriter.enqueue(buffer)
            }
            do { try newEngine.start() }
            catch { input.removeTap(onBus: 0); throw error }
            engine = newEngine
            writer = newWriter
            isRecording = true
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func snapshotForExport() async throws -> AudioSnapshot {
        guard let writer else { return AudioSnapshot(chunks: [], duration: 0) }
        return try await writer.snapshot()
    }

    func stop() async throws -> AudioSnapshot {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        defer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        return try await snapshotForExport()
    }
}
