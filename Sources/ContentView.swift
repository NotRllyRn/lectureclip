import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var store: LectureStore
    @State private var showingSummary = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdvanced = false
    @State private var showingLectures = false
    @State private var editingName = false
    @State private var recordingName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls.padding()
                Divider()
                Picker("Lecture view", selection: $showingSummary) {
                    Text("Transcript").tag(false)
                    Text("Summary").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                if showingSummary {
                    SummaryView(summary: store.session?.summary, through: store.session?.summaryThrough,
                                status: store.notesStatus)
                        .id(store.session?.id)
                } else {
                    TranscriptView(words: store.words, finalizedThrough: store.finalizedThrough,
                                   duration: store.snapshot.duration, status: store.transcriptionStatus)
                }
                Divider()
                exports.padding()
            }
            .frame(maxWidth: 850)
            .frame(maxWidth: .infinity)
            .navigationTitle("LectureClip")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(store.preparingDiagnostics ? "Preparing…" : "Prepare diagnostics") {
                            Task { await store.prepareDiagnostics() }
                        }.disabled(store.preparingDiagnostics)
                        if let url = store.diagnosticsURL {
                            ShareLink(item: url) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                        }
                    } label: { Label("Diagnostics", systemImage: "stethoscope") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingLectures = true } label: { Label("Saved lectures", systemImage: "folder") }
                    .disabled(store.isRecording || store.broadcastPrepared || store.isBusy || store.exporting || store.summarizing)
                }
            }
            .sheet(isPresented: $showingLectures) {
                SavedLecturesView(sessions: store.sessions) { saved in Task { await store.open(saved) } }
            }
            .sheet(isPresented: $showingAdvanced) {
                AdvancedExportView(words: store.words.filter(\.isFinal), duration: store.snapshot.duration) { start, end in
                    showingAdvanced = false
                    Task { await store.export(start: start, end: end) }
                }
            }
            .alert("Name recording", isPresented: $editingName) {
                TextField("Lecture name", text: $recordingName)
                Button("Save") { store.renameRecording(recordingName) }
                    .disabled(recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            }
            .task { await store.activate() }
            .alert("LectureClip", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.activate() } }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if RecordingSource.available.count > 1 {
                Picker("Audio source", selection: $store.source) {
                    ForEach(RecordingSource.available) { source in Text(source.title).tag(source) }
                }
                .pickerStyle(.segmented)
                .disabled(store.isRecording || store.broadcastPrepared || store.isBusy || store.exporting || store.summarizing)
            }
            if let session = store.session {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.displayTitle).font(.headline).lineLimit(2)
                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Name / Rename recording") {
                            recordingName = session.title ?? ""
                            editingName = true
                        }
                        Button("Regenerate recording title") { Task { await store.regenerateRecordingTitle() } }
                            .disabled(store.summarizing || !store.words.contains(where: \.isFinal))
                    } label: { Label("Recording name", systemImage: "pencil").labelStyle(.iconOnly) }
                }
            }
            HStack {
                Label(store.isRecording ? "Recording" : "Saved audio", systemImage: store.isRecording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(store.isRecording ? Color.red : Color.primary)
                Spacer()
                Text(clockString(store.snapshot.duration)).font(.title2.monospacedDigit())
            }
            if store.source == .systemAudio && store.broadcastPrepared {
                HStack {
                    BroadcastPicker().frame(width: 60, height: 60)
                    Text("Tap to start or stop screen broadcast. Only app audio is saved; protected audio may be unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !store.isRecording {
                    Button("Cancel broadcast setup") { store.cancelBroadcastSetup() }.font(.caption)
                }
            } else {
            Button {
                Task {
                    if store.isRecording { await store.stopRecording() }
                    else { await store.startRecording() }
                }
            } label: {
                Label(store.isRecording ? "Stop recording" : (store.source == .systemAudio ? "Prepare system recording" : "New recording"), systemImage: store.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || store.exporting || (store.summarizing && !store.isRecording))
            .accessibilityIdentifier("recordButton")
            }
            Text(store.transcriptionStatus).font(.caption).foregroundStyle(.secondary)
            if !store.modelReady {
                Button(store.preparingModel ? "Preparing model…" : "Download / Retry Parakeet V3") {
                    Task { await store.prepareModel() }
                }.disabled(store.preparingModel)
            } else {
                Button("Retry transcription") { store.startRecognition() }.font(.caption)
            }
        }
    }

    private var exports: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { quickButton; advancedButton }
                VStack { quickButton; advancedButton }
            }
            if !store.canQuickExport && store.snapshot.duration >= 0.1 {
                Text("Quick Export waits for finalized transcription. Advanced Export can export saved audio now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("exportStatus")
            HStack {
                Menu {
                    Text(store.notesStatus)
                    Button("Generate / Refresh notes") { Task { await store.summarize() } }
                        .disabled(store.summarizing || store.isBusy || !store.words.contains(where: \.isFinal))
                    Button("Regenerate clip title") { Task { await store.regenerateClipTitle() } }
                        .disabled(store.summarizing || store.exporting || store.lastClip?.text.isEmpty != false)
                } label: { Label(store.summarizing ? "Generating…" : "Notes & titles", systemImage: "sparkles") }
                Spacer()
                if let clips = store.session?.clips, !clips.isEmpty {
                    Menu {
                        ForEach(clips) { clip in
                            Button(clip.title ?? "Clip \(clockString(clip.start))–\(clockString(clip.end))") { store.selectClip(clip) }
                        }
                    } label: { Label("Saved clips (\(clips.count))", systemImage: "waveform") }
                }
            }.font(.footnote)
            if let clip = store.lastClip {
                Text(clip.title ?? "Lecture clip").font(.subheadline).lineLimit(1)
                HStack {
                    ShareLink(items: [clip.audioURL, clip.transcriptURL]) { Label("Share clip", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button("Copy text") { UIPasteboard.general.string = clip.text }
                }.font(.footnote)
            }
        }
    }

    private var quickButton: some View {
        Button { Task { await store.export() } } label: {
            Label(store.exporting ? "Exporting…" : "Quick Export + Copy", systemImage: "square.on.square").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).disabled(store.exporting || store.isBusy || !store.canQuickExport)
    }

    private var advancedButton: some View {
        Button { showingAdvanced = true } label: {
            Label("Advanced Export", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).disabled(store.exporting || store.isBusy || store.snapshot.duration < 0.1)
    }
}
