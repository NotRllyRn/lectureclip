import Foundation

struct LectureSession: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var timeline = TranscriptTimeline()
    var summary: String?
}

enum SessionStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectures", isDirectory: true)
    }

    static func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func create() throws -> LectureSession {
        let session = LectureSession(id: UUID(), createdAt: Date())
        try FileManager.default.createDirectory(at: directory(session.id), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try save(session)
        return session
    }

    static func save(_ session: LectureSession) throws {
        try JSONEncoder().encode(session).write(to: directory(session.id).appendingPathComponent("session.json"), options: .atomic)
    }

    static func list() throws -> [LectureSession] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .map { try JSONDecoder().decode(LectureSession.self, from: Data(contentsOf: $0.appendingPathComponent("session.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func snapshot(_ id: UUID) throws -> AudioSnapshot {
        let folder = directory(id)
        let index = folder.appendingPathComponent("chunks.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return AudioSnapshot(chunks: [], duration: 0) }
        let chunks = try JSONDecoder().decode([AudioChunk].self, from: Data(contentsOf: index)).map {
            AudioChunk(id: $0.id, url: folder.appendingPathComponent($0.url.lastPathComponent),
                       startFrame: $0.startFrame, frameCount: $0.frameCount, sampleRate: $0.sampleRate)
        }
        return AudioSnapshot(chunks: chunks, duration: chunks.last?.end ?? 0)
    }
}
