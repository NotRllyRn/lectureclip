import AVFoundation
import Foundation

// File state belongs to queue; the semaphore bounds owned buffers awaiting disk.
final class ChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lecture.audio.disk", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let format: AVAudioFormat
    private let directory: URL
    private let preencode: Bool
    private var totalFrames: Int64 = 0
    private var currentFrames: Int64 = 0
    private var file: AVAudioFile?
    private var url: URL?
    private var finished: [AudioChunk] = []
    private var failure: Error?
    private let onFailure: @Sendable (String) -> Void

    init(format: AVAudioFormat, directory: URL, existing: AudioSnapshot = AudioSnapshot(chunks: [], duration: 0), preencode: Bool = true, onFailure: @escaping @Sendable (String) -> Void) {
        self.format = format
        self.directory = directory
        self.preencode = preencode
        finished = existing.chunks
        totalFrames = Int64((existing.duration * format.sampleRate).rounded())
        self.onFailure = onFailure
    }

    // AVAudioEngine invokes this on its audio thread, never the main actor.
    // Keep the callback Sendable even when it is installed from a MainActor method.
    func makeAudioTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable [self] buffer, _ in enqueue(buffer) }
    }

    func enqueue(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
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
        let byteCount = Int(source.frameLength) * Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard src.count == dst.count, zip(src, dst).allSatisfy({
            $0.0.mData != nil && $0.1.mData != nil &&
            Int($0.0.mDataByteSize) >= byteCount && Int($0.1.mDataByteSize) >= byteCount
        }) else {
            slots.signal()
            onFailure("The microphone returned an invalid audio buffer.")
            return
        }
        for (from, to) in zip(src, dst) { memcpy(to.mData!, from.mData!, byteCount) }
        // AVAudioPCMBuffer isn't Sendable. Ownership transfers exclusively to the queue.
        let owned = OwnedBuffer(buffer: buffer)
        queue.async { [self, owned] in
            defer { slots.signal() }
            guard failure == nil else { return }
            do {
                if file == nil {
                    let next = directory.appendingPathComponent("chunk_\(UUID().uuidString).caf")
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
        if preencode { EncodedAudioCache.schedule(finished) }
    }

    private func snapshotOnQueue() throws -> AudioSnapshot {
        try seal()
        if let failure { throw failure }
        return AudioSnapshot(chunks: finished, duration: finished.last?.end ?? 0)
    }

    func finishSynchronously() throws -> AudioSnapshot { try queue.sync { try snapshotOnQueue() } }

    func snapshot() async throws -> AudioSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try snapshotOnQueue()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
