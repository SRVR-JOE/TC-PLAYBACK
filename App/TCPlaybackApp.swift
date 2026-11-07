import SwiftUI
import SwiftData

// Owned by the APP SHELL agent (may extend; keep the model container types).
@main
struct TCPlaybackApp: App {
    init() {
        #if DEBUG
        CueCallerSelfTest.runIfRequested() // -cueCallerTest -silentOutput
        #endif
        // The self-test measures timing with its stand-in voice; everything else gets real speech.
        if !ProcessInfo.processInfo.arguments.contains("-cueCallerTest") { CueCallerWiring.install() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Track.self, Playlist.self, Cue.self, CuePoint.self])
    }
}
