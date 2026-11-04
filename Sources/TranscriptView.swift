import SwiftUI

struct TranscriptView: View {
    let words: [TranscriptWord]
    let finalizedThrough: Double
    let duration: Double
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Transcript", systemImage: "text.bubble").font(.headline)
                        Spacer()
                        Text("Final through \(clockString(finalizedThrough))").font(.caption)
                    }
                    if words.isEmpty {
                        ContentUnavailableView(duration > 0 ? "Waiting for transcription" : "Ready to listen", systemImage: "waveform",
                            description: Text(duration > 0 ? status : "Record now. Download Parakeet V3 to transcribe locally, or catch up from saved audio later."))
                    }
                    ForEach(TranscriptSentence.group(words)) { sentence in
                        TranscriptSentenceRow(sentence: sentence)
                    }
                    Color.clear.frame(height: 1).id("transcriptEnd")

                }.padding()
            }
            .onChange(of: words) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("transcriptEnd", anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo("transcriptEnd", anchor: .bottom) }
        }
    }
}
