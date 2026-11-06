import SwiftUI

struct NotesModelSettings: View {
    @ObservedObject var model: NotesModelController
    @ObservedObject var store: LectureStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Titles and summaries") {
                    Picker("Model", selection: Binding(get: { model.provider }, set: { model.select($0); store.notesModelChanged() })) {
                        ForEach(NotesProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(store.summarizing || model.generating || model.downloading)
                    Text("This choice does not change Parakeet transcription.").font(.footnote)
                }
                if model.provider == .qwen {
                    Section("Qwen3 1.7B · 4-bit") {
                        Text(model.status)
                        Text("About 985 MB of storage, plus memory while generating. After download, titles and summaries run offline with no Apple generation rate limit. Pause recording and let transcription catch up first; keep the app open while generating.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if model.downloading || model.generating {
                            ProgressView()
                            Button("Cancel") { model.cancel() }
                        } else if !model.downloaded {
                            Button("Download Qwen") { model.download() }
                                .disabled(store.isRecordingActive)
                        } else {
                            Button("Generate / Refresh notes") { Task { await store.summarize() } }
                                .disabled(store.summarizing || store.isRecordingActive || !store.words.contains(where: \.isFinal))
                            Button("Remove Qwen download", role: .destructive) { confirmRemoval = true }
                                .disabled(store.summarizing)
                        }
                        Link("Model source and Apache 2.0 license", destination: URL(string: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit")!)
                    }
                } else {
                    Section {
                        Text("Uses Apple Intelligence when available. Apple controls its generation limits; no Qwen download is needed.")
                    }
                }
            }
            .navigationTitle("Notes model")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove the Qwen model download?", isPresented: $confirmRemoval) {
                Button("Remove download", role: .destructive) { model.deleteDownload(); store.notesModelChanged() }
            } message: { Text("Recordings and saved summaries will be kept.") }
            .onChange(of: model.downloaded) { _, _ in store.notesModelChanged() }
        }
    }
}
