import Foundation
import UIKit

@MainActor
enum ClipClipboard {
    /// Put two items on the clipboard without displaying a modal sheet.
    /// Receiving apps decide whether they support pasting multiple items.
    static func copy(_ clip: ExportedClip) {
        let textProvider = NSItemProvider(object: clip.text as NSString)
        guard let audioProvider = NSItemProvider(contentsOf: clip.audioURL) else {
            UIPasteboard.general.string = clip.text
            return
        }
        UIPasteboard.general.setItemProviders(
            [textProvider, audioProvider], localOnly: true,
            expirationDate: Date().addingTimeInterval(3600)
        )
    }
}
