import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecordingWidgets: WidgetBundle {
    var body: some Widget { RecordingWidget() }
}

struct RecordingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack {
                Label("LectureClip recording", systemImage: "mic.fill")
                Spacer()
                Text(context.state.timerStart, style: .timer).monospacedDigit()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Recording", systemImage: "mic.fill") }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.timerStart, style: .timer).monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
            } compactTrailing: {
                Text(context.state.timerStart, style: .timer).monospacedDigit().frame(maxWidth: 60)
            } minimal: {
                Image(systemName: "mic.fill")
            }
        }
    }
}
