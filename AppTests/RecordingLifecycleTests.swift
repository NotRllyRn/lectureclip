import AVFoundation
import ActivityKit
import XCTest
@testable import LectureClip

@MainActor
final class RecordingLifecycleTests: XCTestCase {
    func testRecordingLiveActivityCanStartAndEnd() async throws {
        try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are disabled on this test host.")
        let activity = RecordingActivity()
        await activity.end()
        try activity.start(elapsed: 30)
        let active = Activity<RecordingActivityAttributes>.activities
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.activityState, .active)
        if let start = active.first?.content.state.timerStart {
            XCTAssertEqual(Date().timeIntervalSince(start), 30, accuracy: 3)
        }
        await activity.end()
        XCTAssertTrue(Activity<RecordingActivityAttributes>.activities.allSatisfy { $0.activityState != .active })
    }

    func testShortcutRecordingRequiresActivityAndEndsItOnStopAndFailure() async throws {
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        let transcriptionEnabled = UserDefaults.standard.bool(forKey: "transcriptionEnabled")
        UserDefaults.standard.set(false, forKey: "transcriptionEnabled")
        let capture = TestRecordingCapture()
        let activity = TestRecordingActivity()
        let store = LectureStore(intelligence: NoRecordingNotes(), restore: false, recorder: capture, recordingActivity: activity)
        defer {
            if let id = store.session?.id { try? FileManager.default.removeItem(at: SessionStore.directory(id)) }
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
            UserDefaults.standard.set(transcriptionEnabled, forKey: "transcriptionEnabled")
        }
        activity.fail = true
        let refused = await store.startRecording(reportErrors: false, requiresActivity: true)
        XCTAssertFalse(refused)
        XCTAssertFalse(capture.isRecording)
        XCTAssertNil(store.session)
        activity.fail = false
        let started = await store.startRecording(reportErrors: false, requiresActivity: true)
        XCTAssertTrue(started)
        XCTAssertTrue(activity.active)
        let stopped = await store.stopRecording(reportErrors: false)
        XCTAssertTrue(stopped)
        XCTAssertFalse(activity.active)
        let resumed = await store.resumeRecording(reportErrors: false, requiresActivity: true)
        XCTAssertTrue(resumed)
        XCTAssertEqual(activity.elapsed, 1, accuracy: 0.001)
        XCTAssertTrue(activity.active)
        _ = await store.stopRecording(reportErrors: false)
        capture.failNextStart = true
        let failed = await store.resumeRecording(reportErrors: false, requiresActivity: true)
        XCTAssertFalse(failed)
        XCTAssertFalse(activity.active)
        XCTAssertTrue(store.isRecordingPaused)
    }

    func testStartPauseResumeAndNewLecturePreserveMetadata() async throws {
        let transcriptionEnabled = UserDefaults.standard.bool(forKey: "transcriptionEnabled")
        UserDefaults.standard.set(false, forKey: "transcriptionEnabled")
        defer { UserDefaults.standard.set(transcriptionEnabled, forKey: "transcriptionEnabled") }
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        var ids: [UUID] = []
        defer {
            for id in ids { try? FileManager.default.removeItem(at: SessionStore.directory(id)) }
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
        }
        let capture = TestRecordingCapture()
        let store = LectureStore(intelligence: NoRecordingNotes(), restore: false, recorder: capture)
        XCTAssertFalse(store.isRecordingActive)
        XCTAssertFalse(store.isRecordingPaused)
        let noSession = await store.resumeRecording(reportErrors: false)
        XCTAssertFalse(noSession)
        let started = await store.startRecording(reportErrors: false)
        XCTAssertTrue(started)
        let id = try XCTUnwrap(store.session?.id)
        ids.append(id)
        XCTAssertTrue(store.isRecordingActive)
        XCTAssertFalse(store.isRecordingPaused)
        let duplicateStart = await store.startRecording(reportErrors: false)
        XCTAssertFalse(duplicateStart)
        XCTAssertEqual(store.session?.id, id)
        let stopped = await store.stopRecording(reportErrors: false)
        XCTAssertTrue(stopped)
        XCTAssertFalse(store.isRecordingActive)
        XCTAssertTrue(store.isRecordingPaused)
        XCTAssertTrue(store.canResume)
        let duplicateStop = await store.stopRecording(reportErrors: false)
        XCTAssertFalse(duplicateStop)

        var saved = try XCTUnwrap(store.session)
        saved.rename("Biology lecture")
        saved.timeline.words = [TranscriptWord(text: "Saved words", start: 0, end: 0.5)]
        saved.timeline.finalizedThrough = 1
        saved.timeline.quickExportCursor = 0.5
        saved.summary = "Saved summary"
        saved.summaryThrough = 1
        try SessionStore.save(saved)
        await store.open(saved)
        let original = try XCTUnwrap(store.snapshot.chunks.first)
        let oldBytes = try Data(contentsOf: original.url)
        let resumed = await store.resumeRecording(reportErrors: false)
        XCTAssertTrue(resumed)
        XCTAssertTrue(store.isRecordingActive)
        XCTAssertFalse(store.isRecordingPaused)
        let duplicateResume = await store.resumeRecording(reportErrors: false)
        XCTAssertFalse(duplicateResume)
        let pausedAgain = await store.stopRecording(reportErrors: false)
        XCTAssertTrue(pausedAgain)
        XCTAssertEqual(store.session?.id, id)
        XCTAssertEqual(store.session?.createdAt, saved.createdAt)
        XCTAssertEqual(store.session?.title, "Biology lecture")
        XCTAssertEqual(store.session?.summary, "Saved summary")
        XCTAssertEqual(store.session?.timeline.words, saved.timeline.words)
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 0.5)
        XCTAssertEqual(store.snapshot.duration, 2, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: original.url), oldBytes)

        capture.failNextStart = true
        let failedResume = await store.resumeRecording(reportErrors: false)
        XCTAssertFalse(failedResume)
        XCTAssertTrue(store.isRecordingPaused)
        XCTAssertEqual(store.snapshot.duration, 2, accuracy: 0.001)
        XCTAssertNil(store.errorMessage)
        let newRecording = await store.startRecording(reportErrors: false)
        XCTAssertTrue(newRecording)
        let newID = try XCTUnwrap(store.session?.id)
        ids.append(newID)
        XCTAssertNotEqual(newID, id)
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 0)
        XCTAssertEqual(try SessionStore.snapshot(id).duration, 2, accuracy: 0.001)
        _ = await store.stopRecording(reportErrors: false)
    }

    func testCancelledResumeStopsCaptureAndKeepsSavedAudio() async throws {
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        let transcriptionEnabled = UserDefaults.standard.bool(forKey: "transcriptionEnabled")
        UserDefaults.standard.set(false, forKey: "transcriptionEnabled")
        let capture = TestRecordingCapture()
        let store = LectureStore(intelligence: NoRecordingNotes(), restore: false, recorder: capture)
        let started = await store.startRecording(reportErrors: false)
        XCTAssertTrue(started)
        let id = try XCTUnwrap(store.session?.id)
        defer {
            try? FileManager.default.removeItem(at: SessionStore.directory(id))
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
            UserDefaults.standard.set(transcriptionEnabled, forKey: "transcriptionEnabled")
        }
        _ = await store.stopRecording(reportErrors: false)
        capture.cancelWhenStarted = true
        let request = Task { await store.resumeRecording(reportErrors: false) }
        let resumed = await request.value
        XCTAssertFalse(resumed)
        XCTAssertFalse(capture.isRecording)
        XCTAssertFalse(store.isRecordingActive)
        XCTAssertTrue(store.isRecordingPaused)
        XCTAssertEqual(store.snapshot.duration, 2, accuracy: 0.001)
        XCTAssertEqual(store.session?.id, id)
        XCTAssertEqual(store.session?.timeline.quickExportCursor, 0)
    }

    func testColdRecoveryOfRecordingReportsPausedNotActive() async throws {
        let previousSelection = UserDefaults.standard.string(forKey: "selectedSessionID")
        var saved = try SessionStore.create()
        defer {
            try? FileManager.default.removeItem(at: SessionStore.directory(saved.id))
            UserDefaults.standard.set(previousSelection, forKey: "selectedSessionID")
        }
        saved.recordingState = .recording // Persisted before a process termination.
        try SessionStore.save(saved)
        UserDefaults.standard.set(saved.id.uuidString, forKey: "selectedSessionID")
        let restored = LectureStore(intelligence: NoRecordingNotes(), recorder: TestRecordingCapture())
        XCTAssertEqual(restored.session?.id, saved.id)
        XCTAssertFalse(restored.isRecordingActive)
        XCTAssertTrue(restored.isRecordingPaused)
        XCTAssertEqual(try SessionStore.list().first(where: { $0.id == saved.id })?.recordingState, .paused)
    }

    func testResumeAcrossSampleRatesPreservesFilesAndExportsAcrossBoundary() async throws {
        let session = try SessionStore.create()
        let directory = SessionStore.directory(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let first = ChunkWriter(format: firstFormat, directory: directory) { message in XCTFail(message) }
        let firstBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: 12_345))
        firstBuffer.frameLength = 12_345
        firstBuffer.floatChannelData?[0].update(repeating: 0.25, count: 12_345)
        first.enqueue(firstBuffer)
        let initial = try await first.snapshot()
        let oldURL = try XCTUnwrap(initial.chunks.first?.url)
        let oldBytes = try Data(contentsOf: oldURL)
        let orphan = directory.appendingPathComponent("chunk_000001.caf")
        try Data([1, 2, 3]).write(to: orphan)

        let nextFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let next = ChunkWriter(format: nextFormat, directory: directory, existing: initial) { message in XCTFail(message) }
        let nextBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: nextFormat, frameCapacity: 24_000))
        nextBuffer.frameLength = 24_000
        nextBuffer.floatChannelData?[0].update(repeating: -0.25, count: 24_000)
        next.enqueue(nextBuffer)
        let resumed = try await next.snapshot()
        XCTAssertEqual(resumed.duration, initial.duration + 0.5, accuracy: 1 / 48_000)
        XCTAssertEqual(resumed.chunks.count, 2)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertEqual(try Data(contentsOf: orphan), Data([1, 2, 3]))
        try SegmentedAudioRecorder.validate(resumed)
        let samples = try AudioWindowReader.samples(snapshot: resumed, start: 0, end: resumed.duration)
        XCTAssertEqual(Double(samples.count), resumed.duration * 16_000, accuracy: 4)
        // Repeat to catch the intermittent mixed-format export regression.
        for _ in 0..<5 {
            let clip = try await ClipExporter.export(start: initial.duration - 0.05, end: initial.duration + 0.05,
                                                    words: [], chunks: resumed.chunks)
            defer { ClipExporter.removeFiles(clip) }
            let duration = try await AVURLAsset(url: clip.audioURL).load(.duration)
            XCTAssertEqual(duration.seconds, 0.1, accuracy: 0.02)
            let file = try AVAudioFile(forReading: clip.audioURL)
            let decoded = try AudioWindowReader.read(file, first: 0, count: AVAudioFrameCount(0.09 * file.processingFormat.sampleRate))
            let channel = try XCTUnwrap(decoded.floatChannelData?[0])
            // Both sides of the resume boundary must survive, not merely the container duration.
            let early = Int(0.025 * file.processingFormat.sampleRate)
            let late = Int(0.075 * file.processingFormat.sampleRate)
            XCTAssertGreaterThan(channel[early], 0.1)
            XCTAssertLessThan(channel[late], -0.1)
        }
        try FileManager.default.removeItem(at: oldURL)
        XCTAssertThrowsError(try SegmentedAudioRecorder.validate(resumed))
    }
}

@MainActor
private final class TestRecordingCapture: LectureRecording {
    var isRecording = false
    var onInterruption: ((String) -> Void)?
    var failNextStart = false
    var cancelWhenStarted = false
    private var snapshot = AudioSnapshot(chunks: [], duration: 0)

    func start(directory: URL, existing: AudioSnapshot) async throws {
        if failNextStart { failNextStart = false; throw ClipError.microphoneDenied }
        try SegmentedAudioRecorder.validate(existing)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = ChunkWriter(format: format, directory: directory, existing: existing) { message in XCTFail(message) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData?[0].update(repeating: 0.1, count: 16_000)
        writer.enqueue(buffer)
        snapshot = try await writer.snapshot()
        isRecording = true
        if cancelWhenStarted { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func snapshotForExport() async throws -> AudioSnapshot { snapshot }
    func stop() async throws -> AudioSnapshot { isRecording = false; return snapshot }
}

@MainActor
private struct NoRecordingNotes: LectureIntelligence {
    var isAvailable: Bool { false }
    func title(for text: String) async throws -> String { XCTFail("Unexpected model call"); return "" }
    func summary(for text: String) async throws -> String { XCTFail("Unexpected model call"); return "" }
}

@MainActor
private final class TestRecordingActivity: RecordingActivityControlling {
    var active = false
    var fail = false
    var elapsed = 0.0
    func start(elapsed: TimeInterval) throws {
        if fail { throw ClipError.microphoneDenied }
        self.elapsed = elapsed
        active = true
    }
    func end() async { active = false }
}
