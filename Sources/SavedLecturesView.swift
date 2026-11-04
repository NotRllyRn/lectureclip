import SwiftUI

struct SavedLecturesView: View {
    let sessions: [LectureSession]
    let onSelect: (LectureSession) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                Button {
                    onSelect(session)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            .overlay {
                if sessions.isEmpty { ContentUnavailableView("No saved lectures", systemImage: "folder") }
            }
            .navigationTitle("Saved lectures")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
