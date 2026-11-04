import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var recorder = SegmentedAudioRecorder()
    @State private var words: [TranscriptWord] = []
    @State private var quickExportCursor: TimeInterval = 0
    @State private var lastClip: ExportedClip?
    @State private var showingAdvanced = false
    @State private var exporting = false
    @State private var message = "Start a lecture recording."
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                recordingHeader
                Divider()

                HStack {
                    Label("Live transcript", systemImage: "text.bubble")
                        .font(.headline)
                    Spacer()
                    Text("Finalized words")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(words) { word in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(clockString(word.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)
                                    Text(word.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(word.id)
                            }
                            if words.isEmpty {
                                Text("Transcription will appear here when an ASR engine is connected.")
                                    .foregroundStyle(.secondary)
                                    .padding()
                            }
                        }.padding(.horizontal)
                    }
                    .onChange(of: words.count) { _, _ in
                        if let lastID = words.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await quickExport() }
                    } label: {
                        Label(exporting ? "Exporting..." : "Quick Export + Copy",
                              systemImage: "square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(exporting || (!recorder.isRecording && lastClip == nil))

                    Button {
                        showingAdvanced = true
                    } label: {
                        Label("Advanced Export: Select Time Range", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(exporting || (!recorder.isRecording && words.isEmpty))

                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("exportStatus")
                }
                .padding(.horizontal)

                if let lastClip {
                    HStack {
                        ShareLink(items: [lastClip.audioURL, lastClip.transcriptURL]) {
                            Label("Share last clip", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button("Copy text only") {
                            UIPasteboard.general.string = lastClip.text
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .navigationTitle("Lecture Recorder")
            .sheet(isPresented: $showingAdvanced) {
                AdvancedExportView(words: words,
                                   duration: max(recorder.displayElapsed,
                                                 words.last?.end ?? 0)) { start, end in
                    showingAdvanced = false
                    Task { await advancedExport(start: start, end: end) }
                }
            }
            .alert("Export error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var recordingHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: recorder.isRecording ? "record.circle.fill" : "mic")
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)
                Text(recorder.isRecording ? "Recording" : "Not recording")
                    .font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(clockString(recorder.displayElapsed))
                        .font(.title2.monospacedDigit())
                }
            }
            Button(recorder.isRecording ? "Stop" : "Start Recording") {
                Task { await toggleRecording() }
            }
            .buttonStyle(.borderedProminent)

            // Remove this button after replacing it with final ASR word callbacks.
            Button("Add example transcript words (demo)") { insertDemoWords() }
                .font(.caption)
                .disabled(!recorder.isRecording)
        }.padding(.horizontal)
    }

    private func toggleRecording() async {
        do {
            if recorder.isRecording {
                _ = try await recorder.stop()
                message = "Recording stopped. Existing exports remain available."
            } else {
                try await recorder.start()
                words = []
                quickExportCursor = 0
                lastClip = nil
                message = "Recording started. Quick Export will capture from 00:00."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Replace with a real ASR callback. Only finalized words should enter here.
    private func receiveFinalWords(_ incoming: [TranscriptWord]) {
        words.append(contentsOf: incoming.filter { $0.isFinal && $0.end > $0.start })
        words.sort { $0.start < $1.start }
    }

    private func insertDemoWords() {
        let sentence = ["Capacitors", "in", "parallel", "add", "together", "directly."]
        let end = max(0, recorder.displayElapsed - 0.35)
        let start = max(0, end - 2.0)
        guard end - start > 0.1 else { return }
        let step = (end - start) / Double(sentence.count)
        receiveFinalWords(sentence.enumerated().map { index, word in
            TranscriptWord(text: word, start: start + Double(index) * step,
                           end: start + Double(index + 1) * step)
        })
    }

    /// A successful Quick Export advances the cursor. A failed attempt never does.
    private func quickExport() async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let snapshot = try await recorder.snapshotForExport()
            let start = quickExportCursor
            let end = snapshot.duration
            guard end - start >= 0.025 else { throw ClipError.noNewAudio }
            let clip = try await ClipExporter.export(start: start, end: end,
                                                      words: words, chunks: snapshot.chunks)
            ClipClipboard.copy(clip)
            lastClip = clip
            quickExportCursor = end
            message = "Copied \(clockString(start))–\(clockString(end)): audio + transcript items."
        } catch { errorMessage = error.localizedDescription }
    }

    /// Advanced exports do not modify the Quick Export cursor.
    private func advancedExport(start: TimeInterval, end: TimeInterval) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let snapshot = try await recorder.snapshotForExport()
            let boundedEnd = min(end, snapshot.duration)
            let clip = try await ClipExporter.export(
                start: start, end: boundedEnd, words: words,
                chunks: snapshot.chunks
            )
            ClipClipboard.copy(clip)
            lastClip = clip
            message = "Custom clip copied: \(clockString(start))–\(clockString(boundedEnd))."
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AdvancedExportView: View {
    let words: [TranscriptWord]
    let duration: TimeInterval
    let onExport: (TimeInterval, TimeInterval) -> Void

    @State private var rangeStart: Double
    @State private var rangeEnd: Double

    init(words: [TranscriptWord], duration: TimeInterval,
         onExport: @escaping (TimeInterval, TimeInterval) -> Void) {
        self.words = words
        self.duration = max(0.1, duration)
        self.onExport = onExport
        _rangeStart = State(initialValue: 0)
        _rangeEnd = State(initialValue: max(0.1, duration))
    }

    private var visibleWords: [TranscriptWord] {
        selectedWords(words, start: rangeStart, end: rangeEnd)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Adjust the start and end of the audio interval. The highlighted transcript updates as you drag.")
                    .font(.footnote).foregroundStyle(.secondary)

                HStack {
                    Text("Start: \(clockString(rangeStart))")
                    Spacer()
                    Text(String(format: "%.2fs", rangeStart))
                        .monospacedDigit()
                }
                Slider(value: $rangeStart,
                       in: 0...max(0.001, rangeEnd - 0.025))
                    .accessibilityLabel("Clip start time")

                HStack {
                    Text("End: \(clockString(rangeEnd))")
                    Spacer()
                    Text(String(format: "%.2fs", rangeEnd))
                        .monospacedDigit()
                }
                Slider(value: $rangeEnd,
                       in: min(duration, rangeStart + 0.025)...duration)
                    .accessibilityLabel("Clip end time")

                Text("\(String(format: "%.2f", rangeEnd - rangeStart)) seconds selected")
                    .font(.subheadline.bold())

                Divider()
                Text("Selected transcript preview").font(.headline)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(words) { word in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(String(format: "%.1fs", word.start))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 53, alignment: .leading)
                                    Text(word.text)
                                        .font(.body)
                                    Spacer()
                                }
                                .foregroundStyle(word.start < rangeEnd && word.end > rangeStart
                                                 ? Color.primary : Color.secondary)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 5)
                                .background(word.start < rangeEnd && word.end > rangeStart
                                            ? Color.accentColor.opacity(0.17) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .id(word.id)
                            }
                            if words.isEmpty {
                                Text("No finalized transcript words yet. Audio-only export is available.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: rangeStart) { _, value in
                        if let target = words.last(where: { $0.start <= value })?.id {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                    .onChange(of: rangeEnd) { _, value in
                        if let target = words.last(where: { $0.start <= value })?.id {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                Text("Preview: " + visibleWords.map(\.text).joined(separator: " "))
                    .font(.caption).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onExport(rangeStart, rangeEnd)
                } label: {
                    Label("Export selected audio + transcript", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Advanced Export")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
