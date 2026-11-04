import SwiftUI

struct SummaryView: View {
    let summary: String?
    let through: Double?
    let status: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Study summary").font(.headline)
                if let summary {
                    if let through {
                        Text("Based on transcript through \(clockString(through))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary).textSelection(.enabled)
                    Text("Generated on device. Check against your transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No summary yet", systemImage: "sparkles", description: Text(status))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("summaryView")
    }
}
