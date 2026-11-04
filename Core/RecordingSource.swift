import Foundation

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone, systemAudio
    var id: String { rawValue }
    var title: String { self == .microphone ? "Microphone" : "System audio" }
}
