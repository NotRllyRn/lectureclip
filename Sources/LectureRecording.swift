import Foundation

@MainActor
protocol LectureRecording: AnyObject {
    var isRecording: Bool { get }
    var onInterruption: ((String) -> Void)? { get set }
    func start(directory: URL, existing: AudioSnapshot) async throws
    func snapshotForExport() async throws -> AudioSnapshot
    func stop() async throws -> AudioSnapshot
}
