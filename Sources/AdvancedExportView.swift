import SwiftUI

struct AdvancedExportView: View {
    let words: [TranscriptWord]
    let duration: TimeInterval
    private let sentences: [TranscriptSentence]
    let onExport: (TimeInterval, TimeInterval) -> Void

    @State private var rangeStart: Double
    @State private var rangeEnd: Double

    init(words: [TranscriptWord], duration: TimeInterval,
         onExport: @escaping (TimeInterval, TimeInterval) -> Void) {
        self.words = words
        self.sentences = TranscriptSentence.group(words)
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
                Text("Adjust the start and end of the audio interval. Highlighted words show the selected portion of each sentence as you drag.")
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
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(sentences) { sentence in
                                TranscriptSentenceRow(sentence: sentence, selection: rangeStart..<rangeEnd)
                                    .id(sentence.id)
                            }
                            if words.isEmpty {
                                Text("No finalized transcript words yet. Audio-only export is available.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: rangeStart) { _, value in
                        if let target = (sentences.last(where: { $0.id <= value }) ?? sentences.first)?.id {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                    .onChange(of: rangeEnd) { _, value in
                        if let target = (sentences.last(where: { $0.id < value }) ?? sentences.first)?.id {
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
