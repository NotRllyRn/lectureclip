import ActivityKit
import Foundation

@MainActor
protocol RecordingActivityControlling {
    func start(elapsed: TimeInterval) throws
    func end() async
}

@MainActor
final class RecordingActivity: RecordingActivityControlling {
    func start(elapsed: TimeInterval) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RecordingActivityError.disabled
        }
        _ = try Activity.request(attributes: RecordingActivityAttributes(),
                                 content: ActivityContent(state: .init(timerStart: Date().addingTimeInterval(-elapsed)),
                                                          staleDate: nil), pushType: nil)
        Diagnostics.shortcut("Recording Live Activity started.")
    }

    func end() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

private enum RecordingActivityError: LocalizedError {
    case disabled
    var errorDescription: String? {
        "Enable Live Activities for LectureClip in Settings to record from Shortcuts. Recording in the app remains available."
    }
}
