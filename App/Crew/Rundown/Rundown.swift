import Foundation

// DESIGN NOTE: a rundown is DERIVED from a Playlist and its Cues, not a new SwiftData model.
// A playlist already is the ordered list of acts (one cue = one act, with its track and
// cue points), and Playlist / Cue are frozen contract models. The only things a rundown adds
// (planned start, planned duration, skip, act notes, a running order that can differ live)
// are small and per playlist, so they live in an additive "act metadata" layer: Codable JSON
// in UserDefaults keyed by playlist id (`RundownStore`). Nothing in the library schema
// changes, deleting a cue just leaves an orphan metadata entry that `derive` ignores, and
// the metadata can later move into the .tcshow file without a migration.

/// The per-cue extras a rundown keeps on top of the playlist.
struct ActMetadata: Codable, Equatable {
    /// Seconds from show start; nil = straight after the previous act.
    var plannedStart: TimeInterval?
    /// nil = the cue's own length (track duration / generator duration).
    var plannedDuration: TimeInterval?
    var skip = false
    var notes = ""
    /// Title override (empty = the cue title).
    var title = ""
}

/// Everything stored for one playlist's rundown.
struct RundownMetadata: Codable, Equatable {
    var acts: [UUID: ActMetadata] = [:]
    /// Live running order (cue ids). Empty = playlist order. Cues not listed go to the end in
    /// playlist order, so new cues always appear.
    var order: [UUID] = []
}

/// What the rundown needs from a playlist cue (a value copy; keeps the logic SwiftData-free).
struct RundownSourceCue: Equatable {
    var id: UUID
    var title: String
    var trackID: UUID?
    var duration: TimeInterval
}

extension RundownSourceCue {
    init(cue: Cue) {
        self.init(id: cue.id, title: cue.title, trackID: cue.track?.id, duration: cue.displayDuration)
    }
}

/// One act of the show.
struct Act: Equatable, Identifiable {
    /// The playlist cue's id.
    var id: UUID
    var title: String
    var trackID: UUID?
    var plannedStart: TimeInterval?
    var plannedDuration: TimeInterval
    var skip: Bool
    var notes: String
}

struct Rundown: Equatable {
    var playlistID: UUID
    var name: String
    /// In running order.
    var acts: [Act]

    /// Builds the rundown from playlist cues (in playlist order) plus stored metadata.
    static func derive(playlistID: UUID, name: String, cues: [RundownSourceCue], metadata: RundownMetadata) -> Rundown {
        let byID = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [RundownSourceCue] = metadata.order.compactMap { byID[$0] }
        let listed = Set(ordered.map(\.id))
        ordered += cues.filter { !listed.contains($0.id) }
        let acts = ordered.map { c -> Act in
            let m = metadata.acts[c.id] ?? ActMetadata()
            return Act(id: c.id, title: m.title.isEmpty ? c.title : m.title, trackID: c.trackID,
                       plannedStart: m.plannedStart, plannedDuration: m.plannedDuration ?? c.duration,
                       skip: m.skip, notes: m.notes)
        }
        return Rundown(playlistID: playlistID, name: name, acts: acts)
    }

    static func derive(from playlist: Playlist, metadata: RundownMetadata) -> Rundown {
        derive(playlistID: playlist.id, name: playlist.name, cues: playlist.orderedCues.map(RundownSourceCue.init(cue:)),
               metadata: metadata)
    }

    // MARK: Live edits (return the metadata to store)

    /// Moves the act at `from` to `to` in the running order.
    static func reordered(_ metadata: RundownMetadata, rundown: Rundown, from: Int, to: Int) -> RundownMetadata {
        var ids = rundown.acts.map(\.id)
        guard ids.indices.contains(from) else { return metadata }
        let id = ids.remove(at: from)
        ids.insert(id, at: max(0, min(ids.count, to)))
        var m = metadata; m.order = ids
        return m
    }

    static func settingSkip(_ metadata: RundownMetadata, act: UUID, _ skip: Bool) -> RundownMetadata {
        var m = metadata; m.acts[act, default: ActMetadata()].skip = skip
        return m
    }
}

/// Rundown metadata per playlist, JSON in UserDefaults ("crew.rundown.<playlistID>").
enum RundownStore {
    static func key(_ playlistID: UUID) -> String { "crew.rundown.\(playlistID.uuidString)" }

    static func load(playlistID: UUID, defaults: UserDefaults = .standard) -> RundownMetadata {
        guard let data = defaults.data(forKey: key(playlistID)),
              let m = try? JSONDecoder().decode(RundownMetadata.self, from: data) else { return RundownMetadata() }
        return m
    }

    static func save(_ m: RundownMetadata, playlistID: UUID, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(m) { defaults.set(data, forKey: key(playlistID)) }
    }
}
