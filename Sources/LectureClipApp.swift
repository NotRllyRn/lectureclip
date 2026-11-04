import SwiftUI

@main
struct LectureClipApp: App {
    @StateObject private var store = LectureStore.shared

    var body: some Scene {
        WindowGroup { ContentView(store: store) }
    }
}
