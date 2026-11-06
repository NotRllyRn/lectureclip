import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// One bounded generation at a time. Weights are released after each request.
actor QwenEngine {
    private var busy = false

    func generate(_ text: String, request: NotesRequest, directory: URL = QwenModelFiles.directory, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        #if targetEnvironment(simulator)
        throw QwenError.simulator
        #else
        guard !busy else { throw QwenError.busy }
        guard QwenModelFiles.isDownloaded(at: directory) else { throw QwenError.missingModel }
        busy = true
        defer { busy = false; Memory.clearCache() }
        try Task.checkCancellation()
        Memory.cacheLimit = 64 * 1024 * 1024
        progress("Loading Qwen on device…")
        let model = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: directory))
        try Task.checkCancellation()
        return try await model.perform { context in
            let tokens = context.tokenizer.encode(text: text)
            var results: [String] = []
            // Independent bounded contexts avoid a growing KV cache across a lecture.
            for offset in stride(from: 0, to: tokens.count, by: 2048) {
                try Task.checkCancellation()
                progress(request == .title ? "Generating title…" : "Summarizing section \(offset / 2048 + 1) of \((tokens.count + 2047) / 2048)…")
                let excerpt = context.tokenizer.decode(tokens: Array(tokens[offset..<min(offset + 2048, tokens.count)]))
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(request.instructions), .user(excerpt)], additionalContext: ["enable_thinking": false]))
                try Task.checkCancellation()
                let iterator = try TokenIterator(input: input, model: context.model,
                    parameters: GenerateParameters(maxTokens: request.tokenLimit, temperature: 0.2, topP: 0.8))
                let (stream, task) = MLXLMCommon.generateTask(promptTokenCount: input.text.tokens.size,
                    modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
                let output = await withTaskCancellationHandler {
                    var text = ""
                    for await item in stream {
                        if Task.isCancelled { task.cancel(); break }
                        if let chunk = item.chunk { text += chunk }
                    }
                    await task.value // Drain pending GPU work before releasing the model.
                    return text
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                let cleaned = NotesRequest.cleaned(output)
                guard !cleaned.isEmpty else { throw QwenError.emptyOutput }
                results.append(request == .title ? String(cleaned.prefix(100)) : cleaned)
                if request == .title { break }
            }
            guard !results.isEmpty else { throw QwenError.emptyOutput }
            return results.joined(separator: "\n\n")
        }
        #endif
    }
}
