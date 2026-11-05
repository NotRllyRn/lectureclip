import Combine
import Foundation
import UIKit
import AVFAudio

@MainActor
final class LectureStore: ObservableObject {
    static let shared = LectureStore()
    @Published var source: RecordingSource = .microphone
    @Published private(set) var broadcastPrepared = false
    @Published private(set) var session: LectureSession?
    @Published private(set) var sessions: [LectureSession] = []
    @Published private(set) var snapshot = AudioSnapshot(chunks: [], duration: 0)
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var exporting = false
    @Published private(set) var modelReady = false
    @Published private(set) var preparingModel = false
    @Published private(set) var summarizing = false
    @Published private(set) var lastClip: ExportedClip?
    @Published var errorMessage: String? { didSet { if let errorMessage { Diagnostics.record(errorMessage) } } }
    @Published var status = "Record a lecture or open a saved session." { didSet { Diagnostics.record(status) } }
    @Published var transcriptionStatus = "Download the speech model to enable local transcription." { didSet { Diagnostics.record(transcriptionStatus) } }
    @Published private(set) var diagnosticsURL: URL?
    @Published private(set) var preparingDiagnostics = false
    @Published private(set) var notesStatus = "Automatic title and summary after about two minutes of transcription."
    private let copyClip: @MainActor (ExportedClip) -> Bool
    private let intelligence: any LectureIntelligence
    private var automaticNotesPending = false
    private var earlyNotesAttempted: Set<UUID> = []
    private var finalNotesAttempted: Set<UUID> = []
    private let recordingActivity: any RecordingActivityControlling
    private let recorder: any LectureRecording
    private let transcriber = ParakeetTranscriber()
    private var monitor: Task<Void, Never>?
    private var recognition: Task<Void, Never>?

    var words: [TranscriptWord] { session?.timeline.words ?? [] }
    var finalizedThrough: Double { session?.timeline.finalizedThrough ?? 0 }
    var canQuickExport: Bool { (try? session?.timeline.quickRange(recordedThrough: snapshot.duration)) != nil }

    private var liveBroadcast: BroadcastStatus? {
        guard let state = try? BroadcastStorage.read(BroadcastStatus.self, name: "status.json"), state.isLive else { return nil }
        return state
    }

    var isRecordingActive: Bool { recorder.isRecording || liveBroadcast?.phase == .recording }
    var isRecordingPaused: Bool {
        guard !isRecordingActive, !isBusy else { return false }
        if let broadcast = liveBroadcast { return broadcast.phase == .paused }
        return session?.source != .systemAudio && session?.recordingState == .paused
    }
    var canResume: Bool { isRecordingPaused && !broadcastPrepared && session?.source != .systemAudio }

    init(intelligence: any LectureIntelligence = OnDeviceIntelligence(), restore: Bool = true,
         copyClip: @escaping @MainActor (ExportedClip) -> Bool = ClipClipboard.copy,
         recorder: any LectureRecording = SegmentedAudioRecorder(),
         recordingActivity: any RecordingActivityControlling = RecordingActivity()) {
        self.recordingActivity = recordingActivity
        self.recorder = recorder
        self.copyClip = copyClip
        self.intelligence = intelligence
        recorder.onInterruption = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                await self.stopRecording()
                self.errorMessage = message
            }
        }
        guard restore else { return }
        Diagnostics.shortcut("Restoring store in a new process/store instance.")
        do {
            sessions = try SessionStore.list()
            let broadcast = try? BroadcastStorage.read(BroadcastStatus.self, name: "status.json")
            let selected = UserDefaults.standard.string(forKey: "selectedSessionID").flatMap(UUID.init(uuidString:))
            let latest = broadcast.flatMap { state in state.isLive ? sessions.first(where: { $0.id == state.sessionID }) : nil } ?? sessions.first(where: { $0.id == selected }) ?? sessions.first
            if let latest {
                session = latest
                resetNotesStatus()
                lastClip = latest.clips?.last
                snapshot = try SessionStore.snapshot(latest.id)
                source = latest.source ?? .microphone
                status = "Recovered saved audio. Recording is stopped."
                try markSelectedPaused()
                if source == .systemAudio, let broadcast, broadcast.sessionID == latest.id, broadcast.isLive {
                    isRecording = true
                    broadcastPrepared = true
                    watchBroadcast(id: latest.id)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // A Shortcuts cold launch should restore disk state without loading a large ASR model.
    func activate() async {
        guard UIApplication.shared.applicationState == .active else { return }
        if !modelReady, UserDefaults.standard.bool(forKey: "transcriptionEnabled") { await prepareModel() }
        startRecognition()
        startAutomaticNotes()
    }

    func prepareDiagnostics() async {
        guard !preparingDiagnostics else { return }
        preparingDiagnostics = true
        diagnosticsURL = nil
        defer { preparingDiagnostics = false }
        do {
            diagnosticsURL = try await Diagnostics.report(snapshot: snapshot, finalizedThrough: finalizedThrough,
                                                          recording: isRecording, modelReady: modelReady)
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareModel() async {
        guard !preparingModel else { return }
        preparingModel = true
        transcriptionStatus = "Downloading/loading Parakeet V3. First setup requires internet and substantial storage."
        defer { preparingModel = false }
        do {
            try await transcriber.prepare()
            modelReady = true
            UserDefaults.standard.set(true, forKey: "transcriptionEnabled")
            transcriptionStatus = "Parakeet V3 ready — transcription stays on this device."
            startRecognition()
        } catch { transcriptionStatus = "Model unavailable: \(error.localizedDescription). Tap Download / Retry." }
    }

    @discardableResult
    func startRecording(reportErrors: Bool = true, requiresActivity: Bool = false) async -> Bool {
        guard !Task.isCancelled, !isBusy, !exporting, !isRecordingActive, !broadcastPrepared else { return false }
        if source == .systemAudio { await prepareBroadcast(); return false }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        await cancelRecognition()
        monitor?.cancel()
        var created: LectureSession?
        do {
            let newSession = try SessionStore.create()
            created = newSession
            try await beginMicrophone(newSession, existing: AudioSnapshot(chunks: [], duration: 0), requiresActivity: requiresActivity)
            return true
        } catch {
            if let created, (try? SessionStore.snapshot(created.id).duration) == 0 {
                try? FileManager.default.removeItem(at: SessionStore.directory(created.id))
            }
            sessions = (try? SessionStore.list()) ?? sessions
            reportRecordingError(error, showAlert: reportErrors)
            startRecognition()
            return false
        }
    }

    @discardableResult
    func resumeRecording(reportErrors: Bool = true, requiresActivity: Bool = false) async -> Bool {
        guard !Task.isCancelled, !isBusy, !exporting, !isRecordingActive, !broadcastPrepared,
              let current = session, current.source != .systemAudio else { return false }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        await cancelRecognition()
        monitor?.cancel()
        do {
            let existing = try SessionStore.snapshot(current.id)
            try await beginMicrophone(current, existing: existing, requiresActivity: requiresActivity)
            finalNotesAttempted.remove(current.id)
            if session?.summaryThrough == nil { earlyNotesAttempted.remove(current.id) }
            return true
        } catch {
            snapshot = (try? SessionStore.snapshot(current.id)) ?? snapshot
            reportRecordingError(error, showAlert: reportErrors)
            startRecognition()
            return false
        }
    }

    private func beginMicrophone(_ saved: LectureSession, existing: AudioSnapshot, requiresActivity: Bool) async throws {
        do {
            if requiresActivity {
                await recordingActivity.end() // Remove indicators left by a terminated recording process.
                try Task.checkCancellation()
                try recordingActivity.start(elapsed: existing.duration)
            }
            try await recorder.start(directory: SessionStore.directory(saved.id), existing: existing)
            try Task.checkCancellation()
            // Preserve notes or a manual rename completed while capture was starting.
            var updated = session?.id == saved.id ? session! : saved
            updated.recordingState = .recording
            let newLecture = session?.id != saved.id
            try persist(updated)
            UserDefaults.standard.set(updated.id.uuidString, forKey: "selectedSessionID")
            if newLecture { lastClip = nil }
            source = .microphone
            resetNotesStatus()
            snapshot = existing
            broadcastPrepared = false
            isRecording = true
            status = existing.duration > 0 ? "Recording continued. Paused time is excluded from the audio timeline." : "Recording. Audio is saved independently of transcription."
            watchMicrophone()
            startRecognition()
            if !modelReady, UserDefaults.standard.bool(forKey: "transcriptionEnabled") {
                Task { await prepareModel() }
            }
        } catch {
            _ = try? await recorder.stop()
            if requiresActivity { await recordingActivity.end() }
            throw error
        }
    }

    private func watchMicrophone() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.isRecording else { return }
                do { self.snapshot = try await self.recorder.snapshotForExport() }
                catch {
                    await self.stopRecording()
                    self.errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    @discardableResult
    func stopRecording(reportErrors: Bool = true) async -> Bool {
        guard !isBusy, isRecording else { return false }
        if session?.source == .systemAudio {
            status = "Stop using the screen-broadcast button or the system recording indicator."
            return false
        }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        isRecording = false
        monitor?.cancel()
        monitor = nil
        do {
            snapshot = try await recorder.stop()
            await recordingActivity.end()
            try markSelectedPaused()
            status = "Recording paused. Continue this lecture or start a new recording."
            startRecognition()
            return true
        } catch {
            await recordingActivity.end()
            session?.recordingState = .paused
            if let session { snapshot = (try? SessionStore.snapshot(session.id)) ?? snapshot }
            reportRecordingError(error, showAlert: reportErrors)
            startRecognition()
            return false
        }
    }

    private func markSelectedPaused() throws {
        guard var updated = session, updated.source != .systemAudio,
              updated.recordingState != nil || snapshot.duration > 0 else { return }
        updated.recordingState = .paused
        try persist(updated)
    }

    private func reportRecordingError(_ error: Error, showAlert: Bool) {
        if showAlert { errorMessage = error.localizedDescription }
        Diagnostics.record("Recording action failed: \(error.localizedDescription)")
        if !showAlert { Diagnostics.shortcut("Recording failed: \(error)") }
    }

    func startRecordingFromShortcut() async -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable, AVAudioApplication.shared.recordPermission == .granted,
              !isBusy, !exporting, !isRecordingActive, !broadcastPrepared else { return false }
        source = .microphone
        return await startRecording(reportErrors: false, requiresActivity: true)
    }

    func resumeRecordingFromShortcut() async -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable, AVAudioApplication.shared.recordPermission == .granted else { return false }
        return await resumeRecording(reportErrors: false, requiresActivity: true)
    }

    func open(_ saved: LectureSession) async {
        guard !isRecording, !broadcastPrepared, !isBusy, !exporting, !summarizing else { return }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        await cancelRecognition()
        do {
            sessions = try SessionStore.list()
            guard let fresh = sessions.first(where: { $0.id == saved.id }) else { return }
            snapshot = try SessionStore.snapshot(fresh.id)
            session = fresh
            try markSelectedPaused()
            UserDefaults.standard.set(fresh.id.uuidString, forKey: "selectedSessionID")
            resetNotesStatus()
            source = fresh.source ?? .microphone
            broadcastPrepared = false
            monitor?.cancel()
            lastClip = fresh.clips?.last
            status = "Opened saved lecture."
            startRecognition()
        } catch { errorMessage = error.localizedDescription }
    }

    private func prepareBroadcast() async {
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        await cancelRecognition()
        monitor?.cancel()
        do {
            let newSession = try SessionStore.create(source: .systemAudio)
            try BroadcastStorage.write(BroadcastRequest(sessionID: newSession.id), name: "request.json")
            session = newSession
            UserDefaults.standard.set(newSession.id.uuidString, forKey: "selectedSessionID")
            resetNotesStatus()
            snapshot = AudioSnapshot(chunks: [], duration: 0)
            sessions = try SessionStore.list()
            lastClip = nil
            broadcastPrepared = true
            status = "Ready. Tap the broadcast button, then Start Broadcast. Open your lecture app. Video is discarded."
            watchBroadcast(id: newSession.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelBroadcastSetup() {
        guard !isRecording, let id = session?.id else { return }
        if let state = try? BroadcastStorage.read(BroadcastStatus.self, name: "status.json"), state.sessionID == id, state.isLive {
            isRecording = true
            return
        }
        do {
            if let container = BroadcastStorage.container {
                try FileManager.default.removeItem(at: container.appendingPathComponent("request.json"))
            }
            monitor?.cancel()
            broadcastPrepared = false
            status = "Broadcast setup cancelled."
        } catch { errorMessage = error.localizedDescription }
    }

    private func watchBroadcast(id: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session?.id == id else { return }
                do {
                    if let state = try? BroadcastStorage.read(BroadcastStatus.self, name: "status.json"), state.sessionID == id {
                        self.snapshot = try SessionStore.snapshot(id)
                        self.isRecording = state.isLive
                        self.status = state.message ?? (state.isLive
                            ? "System audio recording. Stop through the system broadcast controls."
                            : "Broadcast stopped or interrupted. Saved system audio is available.")
                        self.startRecognition()
                        if !state.isLive { self.broadcastPrepared = false; return }
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError { return }
                catch { self.errorMessage = error.localizedDescription; return }
            }
        }
    }

    private func cancelRecognition() async {
        recognition?.cancel()
        await recognition?.value
        recognition = nil
    }

    func startRecognition() {
        guard modelReady, recognition == nil, let id = session?.id else { return }
        recognition = Task { [weak self] in
            guard let self else { return }
            defer { self.recognition = nil }
            while !Task.isCancelled, self.session?.id == id {
                let boundary = self.finalizedThrough
                let available = self.snapshot
                let remaining = available.duration - boundary
                if remaining < (self.isRecording ? 3 : 0.025) {
                    if !self.isRecording { self.transcriptionStatus = "Transcript caught up."; self.startAutomaticNotes(); return }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                let start = max(0, boundary - 2)
                let end = min(available.duration, boundary + 6)
                let isLast = !self.isRecording && end == available.duration
                self.transcriptionStatus = "\(remaining > 10 ? "Catching up" : "Transcribing") • \(String(format: "%.1f", remaining))s behind"
                do {
                    let began = Date()
                    let words = try await self.transcriber.transcribe(snapshot: available, start: start, end: end)
                    try Task.checkCancellation()
                    guard var updated = self.session, updated.id == id else { return }
                    updated.timeline.merge(words, windowEnd: end, isLast: isLast)
                    Diagnostics.transcription("Window \(start)...\(end), words=\(words.count), finalized \(boundary) → \(updated.timeline.finalizedThrough), inferenceSeconds=\(Date().timeIntervalSince(began))")
                    guard updated.timeline.finalizedThrough > boundary else { throw TranscriptionProgressError() }
                    try SessionStore.save(updated)
                    self.session = updated
                    self.startAutomaticNotes()
                    if self.isRecording, self.snapshot.duration - self.finalizedThrough < 10 {
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch is CancellationError { return }
                catch {
                    self.transcriptionStatus = "Transcription paused: \(error.localizedDescription). Tap Retry transcription or share diagnostics."
                    Diagnostics.transcription("Paused at \(boundary), window \(start)...\(end): \(error)")
                    return
                }
            }
        }
    }

    @discardableResult
    func export(start: Double? = nil, end: Double? = nil, reportErrors: Bool = true, copyToClipboard: Bool = true) async -> Bool {
        guard !Task.isCancelled, !exporting, !isBusy, let id = session?.id else { return false }
        exporting = true
        defer { exporting = false }
        do {
            if isRecording {
                snapshot = session?.source == .systemAudio ? try SessionStore.snapshot(id) : try await recorder.snapshotForExport()
            }
            guard let current = session else { return false }
            let quick = start == nil
            let range = try quick ? current.timeline.quickRange(recordedThrough: snapshot.duration)
                : (start! ..< min(end ?? snapshot.duration, snapshot.duration))
            let clip = try await ClipExporter.export(start: range.lowerBound, end: range.upperBound,
                                                      words: words, chunks: snapshot.chunks,
                                                      title: "\(current.displayTitle) \(clockString(range.lowerBound))–\(clockString(range.upperBound))")
            // Merge into fresh metadata; recognition/automatic notes may have advanced.
            guard var updated = session, updated.id == id else { ClipExporter.removeFiles(clip); return false }
            if quick { updated.timeline.quickExportCursor = range.upperBound }
            updated.clips = (updated.clips ?? []) + [clip]
            do {
                try Task.checkCancellation()
                if copyToClipboard, !copyClip(clip) { throw ClipError.clipboardUnavailable }
            } catch {
                ClipExporter.removeFiles(clip)
                throw error
            }
            // If saving the cursor fails, keep the files already backing the clipboard.
            // Retrying may copy the same interval, but must never skip it.
            try persist(updated)
            lastClip = clip
            status = "\(copyToClipboard ? "Copied" : "Exported") \(clockString(range.lowerBound))–\(clockString(range.upperBound)). Files saved in Exports."
            return true
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
            Diagnostics.record("Export failed: \(error.localizedDescription)")
            if !reportErrors { Diagnostics.shortcut("Export failed: \(error)") }
            return false
        }
    }

    func quickExportFromShortcut() async -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        return await export(reportErrors: false)
    }

    func quickExportFilesFromShortcut() async -> ExportedClip? {
        guard UIApplication.shared.isProtectedDataAvailable else { return nil }
        guard await export(reportErrors: false, copyToClipboard: false) else { return nil }
        return lastClip
    }

    func runShortcut(_ name: String, operation: () async -> Bool) async -> Bool {
        Diagnostics.shortcut("\(name) requested: \(shortcutState)")
        let result = await operation()
        Diagnostics.shortcut("\(name) result=\(result): \(shortcutState)")
        return result
    }

    private var shortcutState: String {
        "active=\(isRecordingActive), paused=\(isRecordingPaused), busy=\(isBusy), exporting=\(exporting), protected=\(UIApplication.shared.isProtectedDataAvailable), micPermission=\(AVAudioApplication.shared.recordPermission.rawValue), hasSession=\(session != nil), source=\(source), saved=\(snapshot.duration), finalized=\(finalizedThrough), exportCursor=\(session?.timeline.quickExportCursor ?? 0), cancelled=\(Task.isCancelled)"
    }

    private func resetNotesStatus() {
        notesStatus = session?.summaryThrough.map { "Saved summary through \(clockString($0))." }
            ?? "Automatic title and summary after about two minutes of transcription."
    }

    private func persist(_ updated: LectureSession) throws {
        try SessionStore.save(updated)
        session = updated
        sessions.removeAll { $0.id == updated.id }
        sessions.append(updated)
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    func renameRecording(_ name: String) {
        guard var updated = session, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updated.rename(name)
        do { try persist(updated) }
        catch { errorMessage = error.localizedDescription }
    }

    func selectClip(_ clip: ExportedClip) { lastClip = clip }

    func startAutomaticNotes() {
        guard UIApplication.shared.applicationState == .active, !summarizing, !automaticNotesPending, !isBusy,
              let session, words.contains(where: \.isFinal) else { return }
        guard let stage = session.automaticNotesStage(isRecording: isRecording || broadcastPrepared, recordedThrough: snapshot.duration) else { return }
        let needsFinal = stage == .complete
        guard needsFinal ? !finalNotesAttempted.contains(session.id) : !earlyNotesAttempted.contains(session.id) else { return }
        guard intelligence.isAvailable else {
            notesStatus = "Automatic titles and summaries need Apple Intelligence enabled and downloaded. You can name this lecture manually."
            return
        }
        if needsFinal { finalNotesAttempted.insert(session.id) }
        else { earlyNotesAttempted.insert(session.id) }
        automaticNotesPending = true
        let id = session.id
        Task {
            if self.session?.id == id { await generateNotes() }
            automaticNotesPending = false
            startAutomaticNotes()
        }
    }

    func summarize() async {
        guard !automaticNotesPending else { return }
        guard intelligence.isAvailable else {
            errorMessage = "Enable Apple Intelligence and download its model to generate titles and summaries on device."
            return
        }
        await generateNotes()
    }

    private func generateNotes() async {
        guard !summarizing, !isBusy, let current = session else { return }
        guard intelligence.isAvailable else {
            notesStatus = "Enable Apple Intelligence and download its model to generate titles and summaries on device."
            return
        }
        let text = current.timeline.words.filter(\.isFinal).map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        let through = current.timeline.finalizedThrough
        summarizing = true
        notesStatus = "Generating title and summary on device…"
        defer {
            summarizing = false
            // A recording may have stopped while its opening summary was generated.
            startAutomaticNotes()
        }
        do {
            let title = current.title == nil ? try await intelligence.title(for: text) : nil
            let summary = try await intelligence.summary(for: text)
            guard var updated = session, updated.id == current.id else { return }
            updated.applyNotes(title: title, summary: summary, through: through)
            try persist(updated)
            notesStatus = "Summary through \(clockString(through)). Updates automatically when recording and transcription finish."
        } catch {
            earlyNotesAttempted.insert(current.id)
            if !isRecording { finalNotesAttempted.insert(current.id) }
            notesStatus = "Could not generate notes: \(error.localizedDescription). Tap Generate / Refresh notes to retry."
            Diagnostics.record(notesStatus)
        }
    }

    func regenerateRecordingTitle() async {
        guard !summarizing, !automaticNotesPending, let current = session else { return }
        let text = current.timeline.words.filter(\.isFinal).map(\.text).joined(separator: " ")
        guard !text.isEmpty, intelligence.isAvailable else {
            errorMessage = "Title generation needs a finalized transcript and Apple Intelligence."
            return
        }
        summarizing = true
        defer { summarizing = false }
        do {
            let title = try await intelligence.title(for: text)
            guard !title.isEmpty, var updated = session, updated.id == current.id,
                  updated.title == current.title, updated.titleIsManual == current.titleIsManual else { return }
            updated.title = title
            updated.titleIsManual = false
            try persist(updated)
        } catch { errorMessage = error.localizedDescription }
    }

    func regenerateClipTitle() async {
        guard !summarizing, !automaticNotesPending, !exporting, let current = session, let clip = lastClip else { return }
        guard !clip.text.isEmpty, intelligence.isAvailable else {
            errorMessage = "Clip titles need the clip's transcript and Apple Intelligence."
            return
        }
        summarizing = true
        defer { summarizing = false }
        do {
            let title = try await intelligence.title(for: clip.text)
            guard !title.isEmpty, var updated = session, updated.id == current.id,
                  let index = updated.clips?.firstIndex(where: { $0.id == clip.id }) else { return }
            let renamed = try ClipExporter.retitled(clip, title: title)
            updated.clips?[index] = renamed
            do { try persist(updated) }
            catch { ClipExporter.removeFiles(renamed); throw error }
            if lastClip?.id == clip.id { lastClip = renamed; ClipClipboard.copy(renamed) }
            ClipExporter.removeFiles(clip)
        } catch { errorMessage = error.localizedDescription }
    }
}
