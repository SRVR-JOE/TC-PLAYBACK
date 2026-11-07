import Foundation
import TCKit

/// A constant-tempo bar/beat grid laid over a track: tempo, where bar 1 beat 1 falls, metre,
/// and optional named sections ("Verse", "Chorus") that start on a bar. Value type, saved per
/// track as JSON in UserDefaults (`BeatGridStore`).
///
/// Beat indices are 0-based from `firstBeat` (beat 0 = bar 1 beat 1) and may be negative
/// before it. Bars and beats in `barBeat(at:)` are 1-based like a DAW; bar 0 and below are
/// the count-in before `firstBeat`.
struct BeatGrid: Codable, Equatable {
    var bpm: Double
    /// Seconds from the start of the audio file to bar 1 beat 1.
    var firstBeat: TimeInterval
    var beatsPerBar: Int = 4
    var sections: [Section] = []
    /// How dropped and dragged marks snap while this grid exists.
    var snapMode: SnapMode = .off
    /// 0…1 when the grid came from `TempoDetector`; nil when tapped or typed.
    var confidence: Double?

    struct Section: Codable, Equatable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        /// 1-based bar the section starts on.
        var startBar: Int
    }

    enum SnapMode: String, Codable, CaseIterable, Identifiable {
        case off, bar, beat, half, quarter
        var id: String { rawValue }
        var label: String {
            switch self { case .off: "Off"; case .bar: "Bar"; case .beat: "Beat"; case .half: "1/2"; case .quarter: "1/4" }
        }
        /// Grid steps per beat (bar handled separately).
        fileprivate var division: Double {
            switch self { case .off, .bar, .beat: 1; case .half: 2; case .quarter: 4 }
        }
    }

    init(bpm: Double, firstBeat: TimeInterval, beatsPerBar: Int = 4, sections: [Section] = [],
         snapMode: SnapMode = .off, confidence: Double? = nil) {
        self.bpm = bpm; self.firstBeat = firstBeat; self.beatsPerBar = beatsPerBar
        self.sections = sections; self.snapMode = snapMode; self.confidence = confidence
    }

    static let bpmRange: ClosedRange<Double> = 20...400

    // MARK: Geometry

    /// Seconds per beat.
    var beatLength: TimeInterval { 60 / max(Self.bpmRange.lowerBound, bpm) }
    var barLength: TimeInterval { beatLength * Double(max(1, beatsPerBar)) }
    private var bpb: Int { max(1, beatsPerBar) }

    /// Time of beat `n` (0 = bar 1 beat 1).
    func beatTime(_ n: Int) -> TimeInterval { firstBeat + Double(n) * beatLength }
    /// Fractional beat index at `t` (0 at `firstBeat`).
    func beatPosition(at t: TimeInterval) -> Double { (t - firstBeat) / beatLength }
    /// Index of the beat closest to `t`.
    func nearestBeat(to t: TimeInterval) -> Int { Int(beatPosition(at: t).rounded()) }
    /// Start time of 1-based `bar`.
    func barTime(_ bar: Int) -> TimeInterval { beatTime((bar - 1) * bpb) }
    /// 1-based bar whose downbeat is closest to `t`.
    func nearestBar(to t: TimeInterval) -> Int { Int((beatPosition(at: t) / Double(bpb)).rounded()) + 1 }

    /// 1-based (bar, beat) containing `t`. A hair of tolerance so a point placed on a beat
    /// (and frame-rounded) reads as that beat, not the one before.
    func barBeat(at t: TimeInterval) -> (bar: Int, beat: Int) {
        let n = Int((beatPosition(at: t) + 1e-6).rounded(.down))
        let bar = Int((Double(n) / Double(bpb)).rounded(.down))
        return (bar + 1, n - bar * bpb + 1)
    }

    /// Bar.beat text for readouts, e.g. "17.3".
    func barBeatLabel(at t: TimeInterval) -> String {
        let b = barBeat(at: t); return "\(b.bar).\(b.beat)"
    }

    /// `t` moved to the nearest grid line for `mode` (unchanged for `.off`). Not clamped.
    func snap(_ t: TimeInterval, mode: SnapMode) -> TimeInterval {
        switch mode {
        case .off: return t
        case .bar:
            let bars = (beatPosition(at: t) / Double(bpb)).rounded()
            return firstBeat + bars * barLength
        case .beat, .half, .quarter:
            let d = mode.division
            return firstBeat + (beatPosition(at: t) * d).rounded() / d * beatLength
        }
    }

    /// Snaps with this grid's own `snapMode`, never below 0. What the timeline hooks call.
    func snapped(_ t: TimeInterval) -> TimeInterval { snapMode == .off ? t : max(0, snap(t, mode: snapMode)) }

    // MARK: Editing

    /// Moves the grid so a beat (keeping bar numbering where it was as far as possible) lands on `t`.
    mutating func alignBeat(to t: TimeInterval) {
        let k = ((t - firstBeat) / beatLength).rounded()
        firstBeat = t - k * beatLength
    }

    /// Makes `t` a downbeat. The bar nearest `t` keeps its number, so sections stay on the
    /// bars they were on.
    mutating func setDownbeat(at t: TimeInterval) {
        let bar = nearestBar(to: t)
        firstBeat = t - Double((bar - 1) * bpb) * beatLength
    }

    /// Changes the tempo keeping the beat nearest `pivot` where it is (so nudging BPM while
    /// parked mid-song doesn't slide the music under the playhead).
    mutating func setBPM(_ new: Double, pivot: TimeInterval) {
        let n = Double(nearestBeat(to: pivot))
        let anchor = beatTime(Int(n))
        bpm = min(max(new, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
        firstBeat = anchor - n * beatLength
    }

    var sortedSections: [Section] { sections.sorted { $0.startBar < $1.startBar } }

    /// The section playing at `t`, if any.
    func section(at t: TimeInterval) -> Section? {
        let bar = barBeat(at: t).bar
        return sortedSections.last(where: { $0.startBar <= bar })
    }

    // MARK: Export helpers

    /// Times (seconds from file start) where each section begins, sorted, negatives dropped.
    /// For a disguise `Section_Break` column.
    var sectionBreakTimes: [TimeInterval] {
        sortedSections.map { barTime($0.startBar) }.filter { $0 >= 0 }
    }

    /// Beat value for disguise's Beat column with the d3 track set to this grid's BPM: d3
    /// counts beats from the track start (beat 0 = 0 s), so this is `t × bpm / 60`. Set the
    /// d3 track's BPM to `bpm` and the cue lands at `t` exactly.
    func beatValue(at t: TimeInterval) -> Double { t * bpm / 60 }

    /// Musical beat count from bar 1 beat 1 (0-based, fractional). Whole numbers sit on the grid.
    func musicalBeat(at t: TimeInterval) -> Double { beatPosition(at: t) }

    /// Existing export options with the Beat column counted at this grid's tempo.
    func disguiseOptions(_ base: CuePointExport.DisguiseOptions = .init()) -> CuePointExport.DisguiseOptions {
        var o = base; o.bpm = bpm; return o
    }

    // MARK: Codable (tolerant of fields added later)

    private enum CodingKeys: String, CodingKey { case bpm, firstBeat, beatsPerBar, sections, snapMode, confidence }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        firstBeat = try c.decode(Double.self, forKey: .firstBeat)
        beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        snapMode = (try? c.decodeIfPresent(SnapMode.self, forKey: .snapMode)) ?? .off
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

/// Per-track persistence: UserDefaults key "cuePoints.beatGrid.<trackID>", JSON.
enum BeatGridStore {
    static func key(_ trackID: UUID) -> String { "cuePoints.beatGrid.\(trackID.uuidString)" }

    static func load(trackID: UUID, defaults: UserDefaults = .standard) -> BeatGrid? {
        guard let data = defaults.data(forKey: key(trackID)) else { return nil }
        return try? JSONDecoder().decode(BeatGrid.self, from: data)
    }

    /// Saves, or removes the entry when `grid` is nil.
    static func save(_ grid: BeatGrid?, trackID: UUID, defaults: UserDefaults = .standard) {
        guard let grid, let data = try? JSONEncoder().encode(grid) else { defaults.removeObject(forKey: key(trackID)); return }
        defaults.set(data, forKey: key(trackID))
    }
}

/// Tap tempo: average interval of the last `window` taps; a gap longer than `resetGap`
/// starts a new count.
struct TapTempo {
    var window = 8
    var resetGap: TimeInterval = 2
    private(set) var taps: [TimeInterval] = []

    init(window: Int = 8, resetGap: TimeInterval = 2) { self.window = max(2, window); self.resetGap = resetGap }

    /// Registers a tap at `time` (any monotonic clock, seconds). Returns the BPM once there are two taps.
    @discardableResult
    mutating func tap(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        if let last = taps.last, time - last > resetGap || time <= last { taps.removeAll() }
        taps.append(time)
        if taps.count > window { taps.removeFirst(taps.count - window) }
        return bpm
    }

    var bpm: Double? {
        guard taps.count >= 2, let a = taps.first, let b = taps.last, b > a else { return nil }
        return 60 * Double(taps.count - 1) / (b - a)
    }
    var count: Int { taps.count }
    mutating func reset() { taps.removeAll() }
}

// MARK: - disguise export with sections (opt-in; the default exporter is untouched)

extension CuePointExport {
    /// disguise cue table like `disguiseCueTable`, but sections come from the beat grid: the
    /// Beat column is counted at the grid's BPM, `Section_Break` is 1 only on rows that start a
    /// grid section, and a section that doesn't coincide with a point gets its own row (Note =
    /// section name). Within `tolerance` seconds a point and a section share a row.
    static func disguiseCueTable(trackName: String, rows: [CuePointRow], clock: CuePointClock, grid: BeatGrid,
                                 options: DisguiseOptions = .init(), tolerance: TimeInterval = 0.5 / 30) -> String {
        var lines = ["Cue table for \(trackName)", "Beat\tTag\tNote\tTrack_Time\tTC_Time\tSection_Break"]
        func beat(_ t: TimeInterval) -> String { String(format: "%.5f", grid.beatValue(at: t)) }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        func line(_ t: TimeInterval, _ tag: String, _ note: String, _ brk: Bool) -> String {
            [beat(t), tag, clean(note), CuePointClock.dotted(clock.trackTime(t)), CuePointClock.dotted(clock.timecode(at: t)), brk ? "1" : "0"]
                .joined(separator: "\t")
        }
        let sections = grid.sortedSections.map { (time: grid.barTime($0.startBar), name: $0.name) }.filter { $0.time >= 0 }
        var used = Set<Int>()
        func claimSection(near t: TimeInterval) -> Int? {
            guard let s = sections.indices.first(where: { !used.contains($0) && abs(sections[$0].time - t) <= tolerance }) else { return nil }
            used.insert(s); return s
        }
        if options.tcTagAtStart {
            let s0 = claimSection(near: 0)
            lines.append([beat(0), "TC \(clock.start.description)", s0.map { clean(sections[$0].name) } ?? "",
                          CuePointClock.dotted(clock.trackTime(0)), CuePointClock.dotted(clock.start), "1"].joined(separator: "\t"))
        }
        // Pair sections with points first; leftover sections become rows of their own.
        enum Item { case point(CuePointRow, section: Int?), section(Int) }
        var items: [(time: TimeInterval, item: Item)] = rows.sorted(by: { $0.time < $1.time })
            .map { r in (r.time, .point(r, section: claimSection(near: r.time))) }
        for s in sections.indices where !used.contains(s) { items.append((sections[s].time, .section(s))) }
        // Stable by time; a lone section row goes before a point at the same time.
        let ordered = items.enumerated().sorted { a, b in
            if a.element.time != b.element.time { return a.element.time < b.element.time }
            if case .section = a.element.item, case .point = b.element.item { return true }
            if case .point = a.element.item, case .section = b.element.item { return false }
            return a.offset < b.offset
        }.map(\.element)
        for (t, item) in ordered {
            switch item {
            case .point(let r, let sec):
                let note = (sec != nil && r.name.isEmpty) ? sections[sec!].name : r.name
                lines.append(line(t, options.cueTags ? "CUE \(r.number)" : "", note, sec != nil))
            case .section(let s):
                lines.append(line(t, "", sections[s].name, true))
            }
        }
        return lines.joined(separator: "\r\n")
    }
}
