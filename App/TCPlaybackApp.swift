import SwiftUI
import SwiftData

// Owned by the APP SHELL agent (may extend; keep the model container types).
@main
struct TCPlaybackApp: App {
    init() {
        #if DEBUG
        CueCallerSelfTest.runIfRequested() // -cueCallerTest -silentOutput
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Track.self, Playlist.self, Cue.self, CuePoint.self])
    }
}
