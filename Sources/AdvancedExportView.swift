import SwiftUI

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
