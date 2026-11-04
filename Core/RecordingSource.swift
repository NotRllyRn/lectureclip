import Foundation

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone, systemAudio
    static var available: [Self] {
        #if FREE_SIDELOAD
        [.microphone]
        #else
        allCases
        #endif
    }
    var id: String { rawValue }
    var title: String { self == .microphone ? "Microphone" : "System audio" }
}
