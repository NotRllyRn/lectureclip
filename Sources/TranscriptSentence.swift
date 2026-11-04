import NaturalLanguage
import SwiftUI

/// Sentence boundaries follow recognition punctuation, including revisions to the live tail.
struct TranscriptSentence: Identifiable {
    let words: [TranscriptWord]
    var id: Double { words[0].start }

    func text(selection: Range<Double>? = nil) -> AttributedString {
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString((index == 0 ? "" : " ") + word.text)
            if let selection {
                let selected = word.start < selection.upperBound && word.end > selection.lowerBound
                part.foregroundColor = selected ? .primary : .secondary
                if selected { part.backgroundColor = Color.accentColor.opacity(0.17) }
            } else {
                part.foregroundColor = word.isFinal ? .primary : .secondary
            }
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

struct TranscriptSentenceRow: View {
    let sentence: TranscriptSentence
    var selection: Range<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection == nil ? clockString(sentence.id)
                 : "\(clockString(sentence.id))–\(clockString(sentence.words.last!.end))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(sentence.text(selection: selection))
                .font(.body).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
