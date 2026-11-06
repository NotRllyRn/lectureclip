import Combine
import Foundation
import UIKit

@MainActor
final class NotesModelController: ObservableObject, LectureIntelligence {
    static let shared = NotesModelController()
    @Published private(set) var provider: NotesProvider
    @Published private(set) var downloaded = QwenModelFiles.isDownloaded()
    @Published private(set) var downloading = false
    @Published private(set) var generating = false
    @Published private(set) var status = "Qwen needs a one-time download of about 985 MB."
    private let defaults: UserDefaults
    private let engine = QwenEngine()
    private var downloadTask: Task<Void, Never>?
    private var generationTask: Task<String, Error>?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = NotesProvider(rawValue: defaults.string(forKey: "notesProvider") ?? "") ?? .qwen
        if downloaded { status = "Qwen is downloaded. Notes run locally without Apple’s generation rate limit." }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    var isAvailable: Bool {
        provider == .apple ? OnDeviceIntelligence().isAvailable : downloaded && UIApplication.shared.applicationState == .active
    }
    var allowsLiveGeneration: Bool { provider == .apple }
    var unavailabilityReason: String {
        provider == .apple ? OnDeviceIntelligence().unavailabilityReason :
            (downloaded ? "Keep LectureClip open to generate Qwen notes." : "Download Qwen in Notes model settings to generate titles and summaries.")
    }

    func select(_ provider: NotesProvider) {
        guard !generating, !downloading else { return }
        self.provider = provider
        defaults.set(provider.rawValue, forKey: "notesProvider")
    }

    func download() {
        guard !downloading, !generating else { return }
        downloading = true
        status = "Downloading Qwen (about 985 MB). Keep LectureClip open."
        downloadTask = Task.detached(priority: .utility) { [self] in
            do {
                try await QwenModelFiles.download { message in
                    Task { @MainActor in self.status = message }
                }
                await self.downloadFinished(error: nil)
            } catch { await self.downloadFinished(error: error) }
        }
    }

    private func downloadFinished(error: Error?) {
        downloaded = QwenModelFiles.isDownloaded()
        downloading = false
        downloadTask = nil
        status = downloaded ? "Qwen is ready. Notes stay on this device." :
            (error is CancellationError ? "Download cancelled. Tap Download to retry." : "Download failed: \(error?.localizedDescription ?? "Unknown error")")
    }

    func deleteDownload() {
        guard !generating, !downloading else { return }
        do {
            try QwenModelFiles.remove()
            downloaded = false
            status = "Qwen removed. Your recordings and saved notes are unchanged."
        } catch { status = error.localizedDescription }
    }

    func cancel() {
        downloadTask?.cancel()
        generationTask?.cancel()
    }

    func cancelGeneration() async {
        let task = generationTask
        task?.cancel()
        _ = try? await task?.value
    }

    func title(for text: String) async throws -> String {
        if provider == .apple { return try await OnDeviceIntelligence().title(for: text) }
        return try await generate(text, request: .title)
    }

    func summary(for text: String) async throws -> String {
        if provider == .apple { return try await OnDeviceIntelligence().summary(for: text) }
        return try await generate(text, request: .summary)
    }

    private func generate(_ text: String, request: NotesRequest) async throws -> String {
        guard UIApplication.shared.applicationState == .active else { throw QwenError.foregroundRequired }
        guard downloaded else { throw QwenError.missingModel }
        guard !generating, !downloading else { throw QwenError.busy }
        generating = true
        status = "Generating locally with Qwen. Keep LectureClip open."
        let task = Task { [self] in
            try await engine.generate(text, request: request) { [self] message in
                Task { @MainActor in self.status = message }
            }
        }
        generationTask = task
        defer { generationTask = nil; generating = false }
        do {
            let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            status = "Qwen generation complete."
            return output
        } catch {
            status = error is CancellationError ? "Qwen paused. Keep the app open and regenerate notes to retry." : error.localizedDescription
            throw error
        }
    }
}
