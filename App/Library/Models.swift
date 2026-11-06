import Foundation
import SwiftData
import TCKit

// CONTRACT FILE — owned by the LIBRARY agent. Stored properties and the declarations below are
// frozen (UI is coding against them). Additive changes (new computed props, helpers, new files
// under App/Library/) are fine.

/// An imported audio file, copied into Documents/Tracks/.
@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    /// File name inside `Track.directory`.
    var fileName: String
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var importedAt: Date
    /// Filled by background analysis on import: LTC found on which channel ("left"/"right"), first TC, rate.
    var ltcChannel: String?
    var ltcStart: String?
    var ltcRate: String?
    /// Downsampled peak overview for the waveform strip: interleaved [L,R] UInt8 pairs, ~2000 buckets.
    var overview: Data?

    init(title: String, fileName: String, duration: TimeInterval, sampleRate: Double, channelCount: Int) {
        self.id = UUID(); self.title = title; self.fileName = fileName; self.duration = duration
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.importedAt = .now
    }

    static var directory: URL {
        let url = URL.documentsDirectory.appending(path: "Tracks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    var fileURL: URL { Track.directory.appending(path: fileName) }

    var ltcStartTimecode: Timecode? {
        guard let s = ltcStart, let r = ltcRate.flatMap(FrameRate.init(rawValue:)) else { return nil }
        return Timecode(string: s, rate: r)
    }
}

/// What happens when a cue finishes.
enum FollowMode: String, Codable, CaseIterable, Identifiable {
    /// Stop and park on the next cue (standby).
    case stop
    /// Immediately start the next cue.
    case autoContinue
    /// Loop this cue.
    case loop
    var id: String { rawValue }
    var label: String {
        switch self { case .stop: "Stop"; case .autoContinue: "Auto-continue"; case .loop: "Loop" }
    }
}

enum CueKind: String, Codable { case track, generator }

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Manual order of playlists in the sidebar.
    var sortIndex: Int
    @Relationship(deleteRule: .cascade, inverse: \Cue.playlist) var cues: [Cue] = []

    init(name: String, sortIndex: Int = 0) {
        self.id = UUID(); self.name = name; self.createdAt = .now; self.updatedAt = .now; self.sortIndex = sortIndex
    }

    /// Cues sorted by `position`.
    var orderedCues: [Cue] { cues.sorted { $0.position < $1.position } }
}

/// One row in a playlist. Remembers its own routing so a show plays back the same every night.
@Model
final class Cue {
    @Attribute(.unique) var id: UUID
    /// 0-based order within the playlist (source of truth for ordering).
    var position: Int
    /// Operator-facing cue number, editable free text ("1", "2.5", "10A"). Renumber rewrites these.
    var number: String
    var title: String
    var notes: String
    var kindRaw: String
    var track: Track?
    // Generator cues
    var genStart: String
    var genRateRaw: String
    var genDuration: TimeInterval
    var genSideRaw: String
    // Per-cue routing
    var leftEnabled: Bool
    var rightEnabled: Bool
    var swapped: Bool
    var gainDB: Float
    var followRaw: String
    /// Optional colour tag (hex "#RRGGBB") for the row marker.
    var colorHex: String?
    var playlist: Playlist?

    init(position: Int, number: String, title: String, kind: CueKind, track: Track? = nil) {
        self.id = UUID(); self.position = position; self.number = number; self.title = title; self.notes = ""
        self.kindRaw = kind.rawValue; self.track = track
        self.genStart = "01:00:00:00"; self.genRateRaw = FrameRate.fps30.rawValue; self.genDuration = 0
        self.genSideRaw = OutputSide.right.rawValue
        self.leftEnabled = true; self.rightEnabled = true; self.swapped = false; self.gainDB = 0
        self.followRaw = FollowMode.stop.rawValue
    }

    var kind: CueKind { CueKind(rawValue: kindRaw) ?? .track }
    var follow: FollowMode {
        get { FollowMode(rawValue: followRaw) ?? .stop }
        set { followRaw = newValue.rawValue }
    }
    var routing: ChannelRouting {
        get { ChannelRouting(leftEnabled: leftEnabled, rightEnabled: rightEnabled, swapped: swapped, gainDB: gainDB) }
        set { leftEnabled = newValue.leftEnabled; rightEnabled = newValue.rightEnabled; swapped = newValue.swapped; gainDB = newValue.gainDB }
    }
    var generatorConfig: GeneratorConfig {
        let rate = FrameRate(rawValue: genRateRaw) ?? .fps30
        return GeneratorConfig(start: Timecode(string: genStart, rate: rate) ?? .zero(rate), rate: rate,
                               duration: genDuration > 0 ? genDuration : nil,
                               side: OutputSide(rawValue: genSideRaw) ?? .right)
    }
    /// Seconds; 0 for an open-ended generator.
    var displayDuration: TimeInterval { kind == .track ? (track?.duration ?? 0) : genDuration }
    var engineSource: EngineSource {
        switch kind {
        case .track: return track.map { .file($0.fileURL) } ?? .none
        case .generator: return .generator(generatorConfig)
        }
    }
}
