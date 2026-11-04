import Foundation

// Set the same App Group in both targets and their provisioning profiles.
enum BroadcastStorage {
    static let groupID = "group.com.notrllyrn.LectureClip"
    static let extensionID = "com.notrllyrn.LectureClip.Broadcast"
    static var container: URL? {
        #if FREE_SIDELOAD
        nil
        #else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        #endif
    }

    static func write<T: Encodable>(_ value: T, name: String) throws {
        guard let container else { throw BroadcastError.unavailableGroup }
        try JSONEncoder().encode(value).write(to: container.appendingPathComponent(name), options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        guard let container else { throw BroadcastError.unavailableGroup }
        return try JSONDecoder().decode(type, from: Data(contentsOf: container.appendingPathComponent(name)))
    }
}

struct BroadcastRequest: Codable { let sessionID: UUID }

struct BroadcastStatus: Codable {
    enum Phase: String, Codable { case recording, paused, finished, failed }
    let sessionID: UUID
    let phase: Phase
    var updatedAt = Date()
    var message: String?
    var isLive: Bool { (phase == .recording || phase == .paused) && Date().timeIntervalSince(updatedAt) < 15 }
}

enum BroadcastError: LocalizedError {
    case unavailableGroup, missingRequest, formatChanged
    var errorDescription: String? {
        switch self {
        case .unavailableGroup: "System audio requires the LectureClip App Group enabled for both the app and broadcast extension in Xcode signing."
        case .missingRequest: "Open LectureClip, select System audio and prepare a recording before starting the broadcast."
        case .formatChanged: "The system audio format changed. Saved audio is preserved; start a new broadcast to continue."
        }
    }
}
