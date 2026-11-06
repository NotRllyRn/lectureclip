import Foundation

struct LectureStorageReport: Sendable {
    var bytesBySession: [UUID: Int64] = [:]
    var totalBytes: Int64 = 0
    var otherBytes: Int64 = 0
}

/// Counts actual saved file contents, including unindexed audio and exported clips.
enum LectureStorage {
    static var exports: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
    }

    static func clipFiles(_ session: LectureSession) -> Set<URL> {
        Set((session.clips ?? []).flatMap { [$0.audioURL, $0.transcriptURL] }
            .map { exports.appendingPathComponent($0.lastPathComponent).standardizedFileURL }
            .filter { $0.deletingLastPathComponent() == exports.standardizedFileURL })
    }

    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == 2 { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isMissing) ?? false
    }

    static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch { if !isMissing(error) { throw error } }
    }

    static func files(in directory: URL) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var failure: Error?
        guard let walker = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
                if isMissing(error) { return true }
                failure = error; return false
            }) else { throw CocoaError(.fileReadUnknown) }
        var files: Set<URL> = []
        for case let url as URL in walker {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true, values.isSymbolicLink != true { files.insert(url.standardizedFileURL) }
            } catch where isMissing(error) { continue }
        }
        if let failure { throw failure }
        return files
    }

    static func report(sessions: [LectureSession]) throws -> LectureStorageReport {
        var report = LectureStorageReport()
        var assigned: Set<URL> = []
        var all = try files(in: exports)
        for root in [SessionStore.root] + [SessionStore.sharedRoot].compactMap({ $0 }) {
            all.formUnion(try files(in: root))
        }
        var sizes: [URL: Int64] = [:]
        for url in all {
            do { sizes[url] = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            catch where isMissing(error) { continue } // A live writer may replace an index during the scan.
        }
        for session in sessions {
            let owned = try files(in: SessionStore.directory(session.id)).union(clipFiles(session))
            report.bytesBySession[session.id] = owned.reduce(0) { $0 + (sizes[$1] ?? 0) }
            assigned.formUnion(owned)
        }
        report.totalBytes = sizes.values.reduce(0, +)
        report.otherBytes = all.subtracting(assigned).reduce(0) { $0 + (sizes[$1] ?? 0) }
        return report
    }

    static func delete(_ session: LectureSession, keeping others: [LectureSession]) throws {
        let retained = others.reduce(into: Set<URL>()) { $0.formUnion(clipFiles($1)) }
        // Only app-owned export filenames are eligible; never follow persisted absolute paths.
        for file in clipFiles(session).subtracting(retained) {
            try removeIfPresent(file)
        }
        let folder = SessionStore.directory(session.id)
        try removeIfPresent(folder)
    }
}

/// A storage scan must finish before deletion starts, and vice versa.
actor LectureStorageWorker {
    static let shared = LectureStorageWorker()
    func report(sessions: [LectureSession]) throws -> LectureStorageReport { try LectureStorage.report(sessions: sessions) }
    func delete(_ session: LectureSession, keeping others: [LectureSession]) throws { try LectureStorage.delete(session, keeping: others) }
}
