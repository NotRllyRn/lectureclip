import AVFoundation
import ReplayKit

// ReplayKit sends audioApp buffers from other apps; video and microphone buffers
// are deliberately discarded. Never load the speech model in this extension.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var writer: ChunkWriter?
    private var format: AVAudioFormat?
    private var sessionID: UUID?
    private var phase = BroadcastStatus.Phase.recording
    private var terminal = false
    private var flushing = false
    private var timer: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let request = try BroadcastStorage.read(BroadcastRequest.self, name: "request.json")
            let folder = SessionStore.directory(request.sessionID)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("chunks.json").path) else {
                throw BroadcastError.missingRequest
            }
            lock.withLock { sessionID = request.sessionID }
            try BroadcastStorage.write(BroadcastStatus(sessionID: request.sessionID, phase: .recording), name: "status.json")
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lecture.broadcast.heartbeat"))
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            timer.resume()
        } catch { fail(error) }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let incomingFormat = AVAudioFormat(streamDescription: stream) else { return }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: incomingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            pcm.frameLength = AVAudioFrameCount(frames)
            let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
            try lock.withLock {
                guard !terminal, let sessionID else { return }
                if let format, !format.isEqual(incomingFormat) { throw BroadcastError.formatChanged }
                if writer == nil {
                    format = incomingFormat
                    writer = ChunkWriter(format: incomingFormat, directory: SessionStore.directory(sessionID), preencode: false) { [weak self] message in
                        DispatchQueue.global().async { [weak self] in
                            self?.fail(NSError(domain: "LectureClip.Broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                        }
                    }
                }
                writer?.enqueue(pcm)
            }
        } catch { fail(error) }
    }

    override func broadcastPaused() { lock.withLock { phase = .paused }; flush() }
    override func broadcastResumed() { lock.withLock { phase = .recording }; flush() }
    override func broadcastFinished() { finish(error: nil) }

    private func flush() {
        let work: (UUID, ChunkWriter?)? = lock.withLock {
            guard !terminal, !flushing, let sessionID else { return nil }
            flushing = true
            return (sessionID, writer)
        }
        guard let (id, writer) = work else { return }
        Task { [self] in
            do {
                if let writer { _ = try await writer.snapshot() }
                try lock.withLock {
                    defer { flushing = false }
                    guard !terminal else { return }
                    try BroadcastStorage.write(BroadcastStatus(sessionID: id, phase: phase), name: "status.json")
                }
            } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        finish(error: error)
        finishBroadcastWithError(error)
    }

    private func finish(error: Error?) {
        let work: (UUID, ChunkWriter?)? = lock.withLock {
            guard !terminal else { return nil }
            terminal = true
            timer?.cancel()
            guard let sessionID else { return nil }
            return (sessionID, writer)
        }
        guard let (id, writer) = work else { return }
        // ReplayKit may terminate the extension after broadcastFinished returns.
        // Wait for the short disk-queue drain so the final CAF/index is durable.
        var message = error?.localizedDescription
        do { if let writer { _ = try writer.finishSynchronously() } }
        catch { message = error.localizedDescription }
        try? BroadcastStorage.write(BroadcastStatus(sessionID: id, phase: message == nil ? .finished : .failed, message: message), name: "status.json")
    }
}
