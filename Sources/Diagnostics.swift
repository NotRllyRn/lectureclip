import AVFoundation
import UIKit

@MainActor
enum Diagnostics {
    private static let key = "recentDiagnostics"

    static func record(_ message: String) {
        var events = UserDefaults.standard.stringArray(forKey: key) ?? []
        events.append("\(Date().ISO8601Format()) \(message)")
        UserDefaults.standard.set(Array(events.suffix(80)), forKey: key)
    }

    static func shortcut(_ message: String) {
        var events = UserDefaults.standard.stringArray(forKey: "shortcutDiagnostics") ?? []
        events.append("\(Date().ISO8601Format()) pid=\(ProcessInfo.processInfo.processIdentifier) appState=\(UIApplication.shared.applicationState.rawValue) \(message)")
        UserDefaults.standard.set(Array(events.suffix(150)), forKey: "shortcutDiagnostics")
    }

    static func report(snapshot: AudioSnapshot, finalizedThrough: Double, recording: Bool, modelReady: Bool) async throws -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let header = """
        LectureClip \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)
        Generated: \(Date().ISO8601Format())
        Recording: \(recording), model ready: \(modelReady)
        Saved seconds: \(snapshot.duration), finalized through: \(finalizedThrough)
        No audio or transcript is included.

        Shortcut events (appState: 0 active, 1 inactive, 2 background):
        \((UserDefaults.standard.stringArray(forKey: "shortcutDiagnostics") ?? []).joined(separator: "\n"))

        Recent events:
        \((UserDefaults.standard.stringArray(forKey: key) ?? []).joined(separator: "\n"))

        Saved chunks: \(snapshot.chunks.count)
        """
        return try await Task.detached {
            var lines = [header]
            for chunk in snapshot.chunks {
                let metadata = "\(chunk.url.lastPathComponent): start=\(chunk.startFrame), frames=\(chunk.frameCount), Hz=\(chunk.sampleRate)"
                do {
                    let file = try AVAudioFile(forReading: chunk.url)
                    lines.append("\(metadata); actual frames=\(file.length), format=\(file.processingFormat)")
                } catch { lines.append("\(metadata); ERROR: \(error.localizedDescription)") }
            }
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("LectureClip-diagnostics.txt")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
    }
}
