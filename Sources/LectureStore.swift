import Combine
import Foundation
import UIKit

@MainActor
final class LectureStore: ObservableObject {
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
    private let intelligence: any LectureIntelligence
    private var automaticNotesPending = false
    private var earlyNotesAttempted: Set<UUID> = []
    private var finalNotesAttempted: Set<UUID> = []
    private let recorder = SegmentedAudioRecorder()
    private let transcriber = ParakeetTranscriber()
    private var monitor: Task<Void, Never>?
    private var recognition: Task<Void, Never>?

    var words: [TranscriptWord] { session?.timeline.words ?? [] }
    var finalizedThrough: Double { session?.timeline.finalizedThrough ?? 0 }
    var canQuickExport: Bool { (try? session?.timeline.quickRange(recordedThrough: snapshot.duration)) != nil }

    init(intelligence: any LectureIntelligence = OnDeviceIntelligence(), restore: Bool = true) {
        self.intelligence = intelligence
        recorder.onInterruption = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                await self.stopRecording()
                self.errorMessage = message
            }
        }
        guard restore else { return }
        do {
            sessions = try SessionStore.list()
            let broadcast = try? BroadcastStorage.read(BroadcastStatus.self, name: "status.json")
            let latest = broadcast.flatMap { state in state.isLive ? sessions.first(where: { $0.id == state.sessionID }) : nil } ?? sessions.first
            if let latest {
                session = latest
                resetNotesStatus()
                lastClip = latest.clips?.last
                snapshot = try SessionStore.snapshot(latest.id)
                source = latest.source ?? .microphone
                status = "Recovered saved audio. Recording is stopped."
                if source == .systemAudio, let broadcast, broadcast.sessionID == latest.id, broadcast.isLive {
                    isRecording = true
                    broadcastPrepared = true
                    watchBroadcast(id: latest.id)
                }
            }
        } catch { errorMessage = error.localizedDescription }
        if UserDefaults.standard.bool(forKey: "transcriptionEnabled") { Task { await prepareModel() } }
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

    func startRecording() async {
        guard !isBusy, !exporting, !summarizing, !isRecording else { return }
        if source == .systemAudio { await prepareBroadcast(); return }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        await cancelRecognition()
        monitor?.cancel()
        do {
            let newSession = try SessionStore.create()
            sessions = try SessionStore.list()
            try await recorder.start(directory: SessionStore.directory(newSession.id))
            session = newSession
            resetNotesStatus()
            snapshot = AudioSnapshot(chunks: [], duration: 0)
            lastClip = nil
            broadcastPrepared = false
            isRecording = true
            status = "Recording. Audio is saved independently of transcription."
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
            startRecognition()
        } catch {
            errorMessage = error.localizedDescription
            startRecognition()
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        if session?.source == .systemAudio {
            status = "Stop using the screen-broadcast button or the system recording indicator."
            return
        }
        isBusy = true
        defer { isBusy = false; startAutomaticNotes() }
        isRecording = false
        monitor?.cancel()
        monitor = nil
        do { snapshot = try await recorder.stop() }
        catch {
            errorMessage = error.localizedDescription
            if let session { snapshot = (try? SessionStore.snapshot(session.id)) ?? snapshot }
        }
        status = "Recording stopped. Saved audio remains available."
        startRecognition()
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
                self.transcriptionStatus = "Transcribing • \(String(format: "%.1f", remaining))s behind"
                do {
                    let words = try await self.transcriber.transcribe(snapshot: available, start: start, end: end)
                    try Task.checkCancellation()
                    guard var updated = self.session, updated.id == id else { return }
                    updated.timeline.merge(words, windowEnd: end, isLast: isLast)
                    try SessionStore.save(updated)
                    self.session = updated
                    self.startAutomaticNotes()
                    if self.isRecording { try await Task.sleep(for: .seconds(2)) }
                } catch is CancellationError { return }
                catch {
                    self.transcriptionStatus = "Transcription paused: \(error.localizedDescription). Tap Retry transcription or share diagnostics."
                    return
                }
            }
        }
    }

    func export(start: Double? = nil, end: Double? = nil) async {
        guard !exporting, !isBusy, let id = session?.id else { return }
        exporting = true
        defer { exporting = false }
        do {
            if isRecording {
                snapshot = session?.source == .systemAudio ? try SessionStore.snapshot(id) : try await recorder.snapshotForExport()
            }
            guard let current = session else { return }
            let quick = start == nil
            let range = try quick ? current.timeline.quickRange(recordedThrough: snapshot.duration)
                : (start! ..< min(end ?? snapshot.duration, snapshot.duration))
            let clip = try await ClipExporter.export(start: range.lowerBound, end: range.upperBound,
                                                      words: words, chunks: snapshot.chunks,
                                                      title: "\(current.displayTitle) \(clockString(range.lowerBound))–\(clockString(range.upperBound))")
            // Merge into fresh metadata; recognition/automatic notes may have advanced.
            guard var updated = session, updated.id == id else { ClipExporter.removeFiles(clip); return }
            if quick { updated.timeline.quickExportCursor = range.upperBound }
            updated.clips = (updated.clips ?? []) + [clip]
            do { try persist(updated) }
            catch { ClipExporter.removeFiles(clip); throw error }
            ClipClipboard.copy(clip)
            lastClip = clip
            status = "Copied \(clockString(range.lowerBound))–\(clockString(range.upperBound)). Files saved in Exports."
        } catch { errorMessage = error.localizedDescription }
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
