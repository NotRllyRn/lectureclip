import CryptoKit
import Foundation

/// Pinned public weights; no transcript is sent to the model host.
enum QwenModelFiles {
    static let modelID = "mlx-community/Qwen3-1.7B-4bit"
    static let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
    struct Asset: Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
    }
    static let assets: [Asset] = [
        Asset(name: "added_tokens.json", bytes: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        Asset(name: "config.json", bytes: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
        Asset(name: "merges.txt", bytes: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        Asset(name: "model.safetensors", bytes: 968080210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
        Asset(name: "model.safetensors.index.json", bytes: 49731, sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
        Asset(name: "special_tokens_map.json", bytes: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        Asset(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        Asset(name: "tokenizer_config.json", bytes: 9706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
        Asset(name: "vocab.json", bytes: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")    ]
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureClipModels/Qwen3-1.7B-4bit/" + revision, isDirectory: true)
    }
    static func isDownloaded(at directory: URL = QwenModelFiles.directory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("verified").path) && assets.allSatisfy {
            (try? fileSize(directory.appendingPathComponent($0.name))) == $0.bytes
        }
    }
    private static func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }
    static func download(to directory: URL = QwenModelFiles.directory, progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        for asset in assets {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(asset.name)
            if (try? fileSize(destination)) == asset.bytes,
               try digest(destination) == asset.sha256 { continue }
            progress("Downloading \(asset.name)…")
            let remote = URL(string: "https://huggingface.co/\(modelID)/resolve/\(revision)/\(asset.name)")!
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try fileSize(temporary) == asset.bytes else { throw QwenError.invalidDownload }
            progress("Verifying \(asset.name)…")
            guard try digest(temporary) == asset.sha256 else { throw QwenError.invalidDownload }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try Task.checkCancellation()
        try Data(revision.utf8).write(to: directory.appendingPathComponent("verified"), options: .atomic)
    }
    static func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum QwenError: LocalizedError {
    case missingModel, invalidDownload, foregroundRequired, busy, emptyOutput, simulator
    var errorDescription: String? {
        switch self {
        case .missingModel: "Download Qwen in Notes model settings first."
        case .invalidDownload: "A Qwen model file failed verification. Retry the download."
        case .foregroundRequired: "Keep LectureClip open while Qwen generates notes. Tap Generate / Refresh notes to retry."
        case .busy: "Qwen is already working. Wait for it to finish."
        case .emptyOutput: "Qwen returned no usable text. Try generating again."
        case .simulator: "Qwen inference requires a physical iPhone/iPad or Mac; simulator generation is disabled."
        }
    }
}
