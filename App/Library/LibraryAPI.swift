import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

// CONTRACT FILE — owned by the LIBRARY agent. Implement bodies; keep signatures.

/// Imports audio into the library (copy into Documents/Tracks, read metadata, compute the
/// waveform overview and scan for LTC in the background).
@MainActor
enum TrackImporter {
    /// Audio types accepted by the file importer / drop targets.
    static let contentTypes: [UTType] = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]

    /// Import one or more security-scoped URLs. Returns the created Tracks (already inserted).
    /// Analysis (overview + LTC scan) continues in the background and updates the models.
    @discardableResult
    static func importFiles(_ urls: [URL], into context: ModelContext) async throws -> [Track] { [] }

    /// Delete a track and its file (cues referencing it are removed too).
    static func delete(_ track: Track, context: ModelContext) {}
}

/// Playlist editing operations (all save the context).
@MainActor
enum PlaylistEditor {
    static func createPlaylist(named name: String, context: ModelContext) -> Playlist { Playlist(name: name) }
    static func duplicate(_ playlist: Playlist, context: ModelContext) -> Playlist { Playlist(name: playlist.name) }
    static func delete(_ playlist: Playlist, context: ModelContext) {}

    /// Append track cues (number = next integer after the highest numeric cue number).
    static func append(tracks: [Track], to playlist: Playlist, context: ModelContext) {}
    static func appendGenerator(to playlist: Playlist, context: ModelContext) -> Cue {
        Cue(position: 0, number: "1", title: "LTC Generator", kind: .generator)
    }
    /// SwiftUI `.onMove` semantics.
    static func move(in playlist: Playlist, from source: IndexSet, to destination: Int, context: ModelContext) {}
    static func delete(cues: [Cue], from playlist: Playlist, context: ModelContext) {}
    static func duplicate(cue: Cue, in playlist: Playlist, context: ModelContext) {}
    /// Rewrite every cue number: start, start+step, … in current order (e.g. 1,2,3 or 10,20,30).
    static func renumber(_ playlist: Playlist, start: Int = 1, step: Int = 1, context: ModelContext) {}

    /// Share/backup: JSON (+ the audio files) as a single `.tcshow` package URL in tmp.
    static func exportShow(_ playlist: Playlist) throws -> URL { URL.temporaryDirectory }
    static func importShow(from url: URL, context: ModelContext) async throws -> Playlist { Playlist(name: "Imported") }
}

/// Runs a playlist through the engine: standby/GO/next/previous, follow modes, pre-wait.
@MainActor
@Observable
final class ShowController {
    static let shared = ShowController()

    private(set) var playlist: Playlist?
    /// The cue that GO will fire (the "standby" cue).
    private(set) var standbyCue: Cue?
    /// The cue currently loaded/playing in the engine.
    private(set) var activeCue: Cue?

    let engine: PlaybackEngine
    init(engine: PlaybackEngine = .shared) { self.engine = engine }

    func open(_ playlist: Playlist) { self.playlist = playlist; standbyCue = playlist.orderedCues.first }
    /// Make `cue` the standby (single-tap on a row).
    func standby(_ cue: Cue) { standbyCue = cue }
    /// Fire the standby cue (load + play), then advance standby to the next cue.
    func go() {}
    /// Load and play a specific cue immediately (double-tap on a row).
    func play(_ cue: Cue) {}
    func stop() { engine.stop() }
    func next() {}
    func previous() {}
    /// Persist live routing changes made while a cue plays back into that cue.
    func commitRoutingToActiveCue() {}
}
