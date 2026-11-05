import AppIntents

struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Start New Recording" }
    static var description: IntentDescription {
        IntentDescription("Starts a new microphone lecture. Returns true if started, false if busy, already recording, or unavailable. Grant microphone permission, enable Live Activities for LectureClip, and unlock the device.")
    }
    static var supportedModes: IntentModes { .background }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let store = LectureStore.shared
        return .result(value: await store.runShortcut("Start recording") { await store.startRecordingFromShortcut() })
    }
}

struct StopRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Recording" }
    static var description: IntentDescription {
        IntentDescription("Stops microphone capture and saves the current lecture as paused so it can be continued. Returns true on success, false if no microphone recording is active or stopping fails.")
    }
    static var supportedModes: IntentModes { .background }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let store = LectureStore.shared
        return .result(value: await store.runShortcut("Stop recording") { await store.stopRecording(reportErrors: false) })
    }
}

struct ResumeRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Resume Recording" }
    static var description: IntentDescription {
        IntentDescription("Continues the current or last-selected microphone lecture, appending audio without including paused time. Returns true if resumed, false if unavailable or already recording. Requires microphone permission, Live Activities enabled, and an unlocked device.")
    }
    static var supportedModes: IntentModes { .background }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let store = LectureStore.shared
        return .result(value: await store.runShortcut("Resume recording") { await store.resumeRecordingFromShortcut() })
    }
}

struct IsRecordingActiveIntent: AppIntent {
    static var title: LocalizedStringResource { "Is Recording Active" }
    static var description: IntentDescription { IntentDescription("Returns true if LectureClip is currently capturing audio, false otherwise. Does not start recording.") }
    static var supportedModes: IntentModes { .background }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: LectureStore.shared.isRecordingActive)
    }
}

struct IsRecordingPausedIntent: AppIntent {
    static var title: LocalizedStringResource { "Is Recording Paused" }
    static var description: IntentDescription { IntentDescription("Returns true if the selected recording is paused and can be continued, false if recording, busy, or no paused recording is selected. Does not start recording.") }
    static var supportedModes: IntentModes { .background }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: LectureStore.shared.isRecordingPaused)
    }
}
