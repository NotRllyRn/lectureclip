import XCTest
@testable import LectureClip

final class QwenModelTests: XCTestCase {
    func testPartialDownloadIsNeverReportedReady() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(QwenModelFiles.isDownloaded(at: folder))
        try Data("marker".utf8).write(to: folder.appendingPathComponent("verified"))
        try Data("partial".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(QwenModelFiles.isDownloaded(at: folder))
    }

    func testGenerationDoesNotDownloadMissingWeights() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await QwenEngine().generate("Lecture", request: .summary, directory: folder)
            XCTFail("A missing model must not trigger implicit downloading or fake generation")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path)) }
    }
}
