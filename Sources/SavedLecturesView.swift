import SwiftUI

struct SavedLecturesView: View {
    @ObservedObject var store: LectureStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: LectureSession?

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Total lecture storage", value: store.storage.map { size($0.totalBytes) } ?? "Calculating…")
                    if let report = store.storage, report.otherBytes > 0 {
                        LabeledContent("Other saved files", value: size(report.otherBytes)).font(.caption)
                    }
                    if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text("Includes audio, transcripts, summaries, metadata and saved clips. Excludes downloaded AI models and copies shared to other apps. Sizes refresh every five seconds; device storage allocation may differ.")
                }
                Section {
                    ForEach(store.sessions) { session in
                        HStack {
                            Button {
                                Task { await store.open(session) }
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(store.storage?.bytesBySession[session.id].map(size) ?? "Calculating…")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isRecordingActive || store.isRecording || store.broadcastPrepared || store.isBusy || store.exporting || store.summarizing)
                            Spacer()
                            Button(role: .destructive) { pendingDeletion = session } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(session.displayTitle)")
                            .disabled(!store.canDeleteRecordings)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDeletion = session }
                                .disabled(!store.canDeleteRecordings)
                        }
                    }
                    if store.sessions.isEmpty { Text("No saved lectures").foregroundStyle(.secondary) }
                } footer: {
                    if !store.canDeleteRecordings { Text("Pause recording and wait for exports or notes to finish before deleting.") }
                }
            }
            .navigationTitle("Saved lectures")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete this lecture?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { saved in
                Button("Delete lecture", role: .destructive) {
                    pendingDeletion = nil
                    Task { await store.deleteRecording(saved) }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { saved in
                Text("Delete “\(saved.displayTitle)” and its recorded audio, transcript, summary and saved clips? This cannot be undone. Copies already saved in other apps remain there.")
            }
            .alert("LectureClip", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .task {
                while !Task.isCancelled {
                    await store.refreshStorage()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .refreshable { await store.refreshStorage() }
        }
    }
}
