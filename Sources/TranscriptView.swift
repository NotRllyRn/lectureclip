import NaturalLanguage
import SwiftUI

/// Sentence boundaries follow recognition punctuation, including revisions to the live tail.
private struct TranscriptSentence: Identifiable {
    let words: [TranscriptWord]
    var id: Double { words[0].start }

    var text: AttributedString {
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString((index == 0 ? "" : " ") + word.text)
            part.foregroundColor = word.isFinal ? .primary : .secondary
            result.append(part)
        }
        return result
    }

    static func group(_ words: [TranscriptWord]) -> [Self] {
        let text = words.map(\.text).joined(separator: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [Self] = []
        var wordIndex = 0
        var offset = 0
        var boundary = text.startIndex
        var end = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            end += text.distance(from: boundary, to: range.upperBound)
            boundary = range.upperBound
            let first = wordIndex
            while wordIndex < words.count && offset < end {
                offset += words[wordIndex].text.count + 1
                wordIndex += 1
            }
            if first < wordIndex { sentences.append(Self(words: Array(words[first..<wordIndex]))) }
            return true
        }
        return sentences
    }
}

struct TranscriptView: View {
    let words: [TranscriptWord]
    let finalizedThrough: Double
    let duration: Double
    let status: String
    let summary: String?
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clockString(sentence.id)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(sentence.text)
                                .font(.body).lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 1).id("transcriptEnd")
                    if let summary {
                        Divider()
                        Text("Study summary").font(.headline)
                        Text(summary).textSelection(.enabled)
                        Text("Generated on device. Check against your transcript.").font(.caption).foregroundStyle(.secondary)
                    }
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
