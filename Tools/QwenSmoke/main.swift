import Foundation

@main
struct QwenSmoke {
    static func main() async throws {
        try await QwenModelFiles.download { print($0) }
        let engine = QwenEngine()
        let transcript = """
        Today's biology lecture explains cellular respiration. Mitochondria produce ATP, which powers cellular work. Glycolysis occurs in the cytoplasm. The electron transport chain is in the inner mitochondrial membrane. Oxygen is the final electron acceptor. Fermentation regenerates NAD+ when oxygen is unavailable; it produces far less ATP than aerobic respiration.
        """
        let start = Date()
        let title = try await engine.generate(transcript, request: .title)
        let summary = try await engine.generate(transcript, request: .summary)
        guard !title.isEmpty, summary.lowercased().contains("atp"),
              summary.lowercased().contains("mitochond"),
              !title.contains("<think>"), !summary.contains("<think>") else {
            throw QwenError.emptyOutput
        }
        print("TITLE: \(title)\nSUMMARY:\n\(summary)\nElapsed: \(Date().timeIntervalSince(start)) seconds")
        // A pre-cancelled request must not generate or return a partial summary.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.generate(transcript, request: .summary)
        }
        do { _ = try await cancelled.value; fatalError("Cancellation was ignored") }
        catch is CancellationError { print("Cancellation verified") }
    }
}
