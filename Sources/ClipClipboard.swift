import Foundation
import UIKit

@MainActor
enum ClipClipboard {
    /// Put two items on the clipboard without displaying a modal sheet.
    /// Receiving apps decide whether they support pasting multiple items.
    @discardableResult
    static func copy(_ clip: ExportedClip) -> Bool {
        let textProvider = NSItemProvider(object: clip.text as NSString)
        guard FileManager.default.fileExists(atPath: clip.audioURL.path),
              let audioProvider = NSItemProvider(contentsOf: clip.audioURL) else { return false }
        let pasteboard = UIPasteboard.general
        let previousChange = pasteboard.changeCount
        pasteboard.setItemProviders(
            [textProvider, audioProvider], localOnly: true,
            expirationDate: Date().addingTimeInterval(3600)
        )
        // Check write acceptance using metadata only; do not read another app's clipboard data.
        return pasteboard.changeCount != previousChange && pasteboard.numberOfItems >= 2
    }
}
