import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = LectureStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdvanced = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls.padding()
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Transcript", systemImage: "text.bubble").font(.headline)
                            Spacer()
                            Text("Final through \(clockString(store.finalizedThrough))").font(.caption)
                        }
                        if store.words.isEmpty {
                            ContentUnavailableView("Ready to listen", systemImage: "waveform",
                                description: Text("Record now. Download Parakeet V3 to transcribe locally, or catch up from saved audio later."))
                        }
                        ForEach(store.words) { word in
                            HStack(alignment: .firstTextBaseline) {
                                Text(clockString(word.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(word.text).foregroundStyle(word.isFinal ? Color.primary : Color.secondary)
                            }
                        }
                        if let summary = store.session?.summary {
                            Divider()
                            Text("Study summary").font(.headline)
                            Text(summary).textSelection(.enabled)
                            Text("Generated on device. Check against your transcript.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding()
                }
                Divider()
                exports.padding()
            }
            .frame(maxWidth: 850)
            .frame(maxWidth: .infinity)
            .navigationTitle("LectureClip")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.sessions) { session in
                            Button(session.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                                Task { await store.open(session) }
                            }
                        }
                    } label: { Label("Saved lectures", systemImage: "folder") }
                    .disabled(store.isRecording || store.isBusy || store.exporting || store.summarizing)
                }
            }
            .sheet(isPresented: $showingAdvanced) {
                AdvancedExportView(words: store.words.filter(\.isFinal), duration: store.snapshot.duration) { start, end in
                    showingAdvanced = false
                    Task { await store.export(start: start, end: end) }
                }
            }
            .alert("LectureClip", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.startRecognition() }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(store.isRecording ? "Recording" : "Saved audio", systemImage: store.isRecording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(store.isRecording ? Color.red : Color.primary)
                Spacer()
                Text(clockString(store.snapshot.duration)).font(.title2.monospacedDigit())
            }
            Button {
                Task {
                    if store.isRecording { await store.stopRecording() }
                    else { await store.startRecording() }
                }
            } label: {
                Label(store.isRecording ? "Stop recording" : "New recording", systemImage: store.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || store.exporting || store.summarizing)
            .accessibilityIdentifier("recordButton")
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
            Text(store.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("exportStatus")
            if let clip = store.lastClip {
                HStack {
                    ShareLink(items: [clip.audioURL, clip.transcriptURL]) { Label("Share clip", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button("Copy text") { UIPasteboard.general.string = clip.text }
                }.font(.footnote)
            }
            Button(store.summarizing ? "Summarizing…" : "Summarize saved transcript") { Task { await store.summarize() } }
                .font(.footnote)
                .disabled(store.isRecording || store.summarizing || store.isBusy || store.snapshot.duration - store.finalizedThrough >= 0.025 || !store.words.contains(where: \.isFinal))
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
