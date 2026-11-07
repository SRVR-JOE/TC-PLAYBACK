import Foundation
import SwiftData

/// disguise cue tables for USB: one "<track>_cue_table.txt" per track, saved into
/// `objects/table` on the drive. Copy the drive's `objects` folder into the disguise project
/// folder (or point Designer at the files) to load them.
@MainActor
enum CueTableExport {
    /// Where Designer keeps cue tables inside a project folder.
    static let disguiseFolder = "objects/table"

    static func isDisguise(_ f: CuePointFormat) -> Bool { f == .disguise || f == .disguisePerType }

    /// Writes the disguise cue table of every track in `playlist` that has marks. Returns the
    /// temp files (empty when no track has marks). Same output as Cue points › Export › disguise.
    static func disguiseTables(for playlist: Playlist, context: ModelContext,
                               options: CuePointExport.DisguiseOptions = .init()) throws -> [URL] {
        var urls: [URL] = []
        var seen = Set<UUID>()
        let types = CuePointTypeStore.shared.types
        for cue in playlist.orderedCues {
            guard let track = cue.track, seen.insert(track.id).inserted else { continue }
            let points = CuePoint.points(for: track.id, in: context)
            guard !points.isEmpty else { continue }
            let index = CuePointIndex(points: points, types: types)
            // Single-table export: numbered across the whole track, like the Cue points export.
            let rows = CuePointRow.rows(for: points, index: index).enumerated().map { i, r in
                var r = r; r.number = i + 1; return r
            }
            let clock = CuePointClock.forTrack(track)
            let grid = BeatGridStore.load(trackID: track.id)
            let opts = grid.map { $0.disguiseOptions(options) } ?? options
            let text: String
            if let grid, !grid.sections.isEmpty {
                text = CuePointExport.disguiseCueTable(trackName: track.title, rows: rows, clock: clock, grid: grid, options: opts)
            } else {
                text = CuePointExport.disguiseCueTable(trackName: track.title, rows: rows, clock: clock, options: opts)
            }
            urls.append(try CuePointExport.write(text, name: CuePointExport.disguiseFileName(trackName: track.title)))
        }
        return urls
    }
}
