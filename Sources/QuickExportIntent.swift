import AppIntents

struct QuickExportIntent: AppIntent {
    static var title: LocalizedStringResource { "Quick Export and Copy" }
    static var description: IntentDescription {
        IntentDescription("Exports the next finalized part of the current or last-selected lecture and copies its audio and transcript. Returns true on success, false if unavailable or unsuccessful. Requires an unlocked device; does not start recording or wait for transcription.")
    }
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: await LectureStore.shared.quickExportFromShortcut())
    }
}

struct LectureClipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickExportIntent(),
                    phrases: ["Quick export with \(.applicationName)"],
                    shortTitle: "Quick Export and Copy", systemImageName: "doc.on.clipboard")
    }
}
