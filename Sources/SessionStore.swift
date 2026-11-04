import Foundation

struct LectureSession: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var timeline = TranscriptTimeline()
    var summary: String?
    var source: RecordingSource?
}

enum SessionStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectures", isDirectory: true)
    }

    static var sharedRoot: URL? { BroadcastStorage.container?.appendingPathComponent("Lectures", isDirectory: true) }

    static func directory(_ id: UUID) -> URL {
        let local = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return sharedRoot?.appendingPathComponent(id.uuidString, isDirectory: true) ?? local
    }

    static func create(source: RecordingSource = .microphone) throws -> LectureSession {
        if source == .systemAudio && sharedRoot == nil { throw BroadcastError.unavailableGroup }
        let session = LectureSession(id: UUID(), createdAt: Date(), source: source)
        let folder = (source == .systemAudio ? sharedRoot! : root).appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do { try save(session) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return session
    }

    static func save(_ session: LectureSession) throws {
        try JSONEncoder().encode(session).write(to: directory(session.id).appendingPathComponent("session.json"), options: .atomic)
    }

    static func list() throws -> [LectureSession] {
        try ([root] + [sharedRoot].compactMap { $0 })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
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
