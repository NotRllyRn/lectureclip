import AVFoundation
import Combine
import Foundation

private struct CaptureFailure: LocalizedError {
    let errorDescription: String?
}

// File state belongs to queue; the semaphore bounds owned buffers awaiting disk.
private final class ChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lecture.audio.disk", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let format: AVAudioFormat
    private let directory: URL
    private var totalFrames: Int64 = 0
    private var currentFrames: Int64 = 0
    private var file: AVAudioFile?
    private var url: URL?
    private var finished: [AudioChunk] = []
    private var failure: Error?
    private let onFailure: @Sendable (String) -> Void

    init(format: AVAudioFormat, directory: URL, onFailure: @escaping @Sendable (String) -> Void) {
        self.format = format
        self.directory = directory
        self.onFailure = onFailure
    }

    func enqueue(_ source: AVAudioPCMBuffer) {
        guard slots.wait(timeout: .now()) == .success else {
            onFailure("Audio storage could not keep up. Recording stopped; saved audio is preserved.")
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            slots.signal()
            onFailure("Could not allocate an audio buffer.")
            return
        }
        buffer.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (from, to) in zip(src, dst) {
            if let fromData = from.mData, let toData = to.mData {
                memcpy(toData, fromData, Int(from.mDataByteSize))
            }
        }
        // AVAudioPCMBuffer isn't Sendable. Ownership transfers exclusively to the queue.
        let owned = OwnedBuffer(buffer: buffer)
        queue.async { [self, owned] in
            defer { slots.signal() }
            guard failure == nil else { return }
            do {
                if file == nil {
                    let next = directory.appendingPathComponent(String(format: "chunk_%06d.caf", finished.count))
                    url = next
                    file = try AVAudioFile(forWriting: next, settings: format.settings,
                                           commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: next.path)
                }
                try file?.write(from: owned.buffer)
                currentFrames += Int64(owned.buffer.frameLength)
                totalFrames += Int64(owned.buffer.frameLength)
                if Double(currentFrames) / format.sampleRate >= 5 { try seal() }
            } catch {
                failure = error
                onFailure(error.localizedDescription)
            }
        }
    }

    private struct OwnedBuffer: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

    private func seal() throws {
        guard let url, file != nil else { return }
        file = nil // Releasing the sole writer closes the CAF before readers open it.
        if currentFrames > 0 {
            finished.append(AudioChunk(id: UUID(), url: url, startFrame: totalFrames - currentFrames,
                                       frameCount: currentFrames, sampleRate: format.sampleRate))
        }
        self.url = nil
        currentFrames = 0
        try JSONEncoder().encode(finished).write(to: directory.appendingPathComponent("chunks.json"), options: .atomic)
    }

    func snapshot() async throws -> AudioSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try seal()
                    if let failure { throw failure }
                    continuation.resume(returning: AudioSnapshot(chunks: finished, duration: Double(totalFrames) / format.sampleRate))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
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
