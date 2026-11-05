import AppIntents
import UniformTypeIdentifiers

struct QuickExportIntent: AppIntent {
    static var title: LocalizedStringResource { "Quick Export and Copy (Opens App)" }
    static var description: IntentDescription {
        IntentDescription("Exports the next finalized part of the current or last-selected lecture and copies its audio and transcript. Returns true on success, false if unavailable or unsuccessful. Opens LectureClip for clipboard access. To stay in the background, use Quick Export Files followed by Shortcuts Copy to Clipboard.")
    }
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let store = LectureStore.shared
        return .result(value: await store.runShortcut("Quick export and copy") { await store.quickExportFromShortcut() })
    }
}

struct QuickExportFilesIntent: AppIntent {
    static var title: LocalizedStringResource { "Quick Export Files" }
    static var description: IntentDescription {
        IntentDescription("Returns the next finalized audio clip and transcript file without opening LectureClip. Follow with Copy to Clipboard, Share, or Save File in Shortcuts. Returns an empty list on failure or if no new finalized audio exists. The export cursor advances when files are saved; downstream Shortcuts actions cannot be verified by LectureClip.")
    }
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let store = LectureStore.shared
        var clip: ExportedClip?
        _ = await store.runShortcut("Quick export files") {
            clip = await store.quickExportFilesFromShortcut()
            return clip != nil
        }
        guard let clip else { return .result(value: [IntentFile]()) }
        let files = [IntentFile(fileURL: clip.audioURL, filename: clip.audioURL.lastPathComponent, type: .mpeg4Audio),
                     IntentFile(fileURL: clip.transcriptURL, filename: clip.transcriptURL.lastPathComponent, type: .plainText)]
        return .result(value: files.map { file in
            var retained = file
            retained.removedOnCompletion = false // Also belongs to the saved clip history.
            return retained
        })
    }
}

struct LectureClipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickExportFilesIntent(),
                    phrases: ["Quick export with \(.applicationName)"],
                    shortTitle: "Quick Export Files", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start New Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["Stop recording with \(.applicationName)"],
                    shortTitle: "Stop Recording", systemImageName: "stop.circle")
        AppShortcut(intent: ResumeRecordingIntent(), phrases: ["Resume recording with \(.applicationName)"],
                    shortTitle: "Resume Recording", systemImageName: "play.circle")
        AppShortcut(intent: IsRecordingActiveIntent(), phrases: ["Is \(.applicationName) recording"],
                    shortTitle: "Is Recording Active", systemImageName: "waveform")
        AppShortcut(intent: IsRecordingPausedIntent(), phrases: ["Is \(.applicationName) paused"],
                    shortTitle: "Is Recording Paused", systemImageName: "pause.circle")
    }
}
