import Foundation

/// One suggested moment from `SongAnalyzer`: a guess, never a mark until someone accepts it.
struct SongMoment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case hit, drop, build, breakdown, stop, section
        var id: String { rawValue }
        /// Plain names for filters and readouts.
        var title: String {
            switch self {
            case .hit: "Hits"; case .drop: "Drops"; case .build: "Builds"; case .breakdown: "Breakdowns"
            case .stop: "Stops"; case .section: "Sections"
            }
        }
        var singular: String {
            switch self {
            case .hit: "Hit"; case .drop: "Drop"; case .build: "Build"; case .breakdown: "Breakdown"
            case .stop: "Stop"; case .section: "Section"
            }
        }
        /// Cue type a suggestion of this kind goes to by default (matched by name; the default
        /// "Cue" type when the user has no type of that name).
        var suggestedTypeName: String {
            switch self {
            case .hit, .build, .breakdown, .stop: "Lights"
            case .drop: "Special FX"
            case .section: "Cue"
            }
        }
    }

    var id = UUID()
    /// Seconds from the start of the file (snapped to the beat grid where that made sense).
    var time: TimeInterval
    var kind: Kind
    /// 0…1, how clear the evidence is. Not a probability.
    var strength: Double
    /// Suggested name, e.g. "Chorus 2", "Drop", "Hit".
    var label: String
    var cueTypeName: String
    /// Sections only: repeat group, 0 = A, 1 = B… Sections in the same group sound alike.
    var group: Int?
    /// One plain sentence on why this was suggested.
    var detail: String = ""

    /// "A", "B"… for a section's repeat group.
    var groupLetter: String? { group.map { SongMoment.letter($0) } }
    static func letter(_ g: Int) -> String {
        let scalars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return g < scalars.count ? String(scalars[g]) : "S\(g + 1)"
    }
}

/// Everything one analysis pass found for a track.
struct SongAnalysis: Codable, Equatable {
    var version: Int
    var duration: TimeInterval
    /// Grid from the tempo pass with the guessed sections, offered when the track has none.
    var grid: BeatGrid?
    var tempoConfidence: Double?
    var moments: [SongMoment]
    /// Wall time of the pass, seconds.
    var elapsed: TimeInterval
    /// Where the music starts and stops (seconds).
    var musicStart: TimeInterval
    var musicEnd: TimeInterval

    // MARK: Filtering

    /// Minimum strength shown at `sensitivity` (0 = fewest suggestions, 1 = most).
    /// 0.5 (the default) keeps the clear ones. Sections and stops are gentler: a song only has
    /// a handful, and each one usually matters.
    static func threshold(sensitivity: Double, kind: SongMoment.Kind) -> Double {
        let s = min(1, max(0, sensitivity))
        let base = 0.8 - 0.6 * s                       // 0.8 … 0.2, 0.5 at default
        switch kind {
        case .section, .stop: return base * 0.6
        case .hit, .drop, .build, .breakdown: return base
        }
    }

    /// Moments of `kinds` above the sensitivity threshold, minus `rejected`, in time order.
    func visible(sensitivity: Double, kinds: Set<SongMoment.Kind> = Set(SongMoment.Kind.allCases),
                 rejected: Set<UUID> = []) -> [SongMoment] {
        moments.filter { kinds.contains($0.kind) && !rejected.contains($0.id)
            && $0.strength >= Self.threshold(sensitivity: sensitivity, kind: $0.kind) }
            .sorted { $0.time < $1.time }
    }

    /// Section moments in time order (every one, regardless of sensitivity).
    var sections: [SongMoment] { moments.filter { $0.kind == .section }.sorted { $0.time < $1.time } }

    /// `grid` (or `base`, keeping its tempo and phase) with sections taken from the section
    /// suggestions, each starting on the bar nearest its time.
    func gridWithSections(base: BeatGrid?) -> BeatGrid? {
        guard var g = base ?? grid else { return nil }
        var seen = Set<Int>()
        g.sections = sections.compactMap { m in
            let bar = max(1, g.nearestBar(to: m.time))
            guard seen.insert(bar).inserted else { return nil }
            return BeatGrid.Section(name: m.label, startBar: bar)
        }
        return g
    }
}
