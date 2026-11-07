import Foundation

/// Bars and whole beats left until a time on the grid (e.g. "2 bars 3 beats").
struct BarsBeats: Equatable {
    var bars: Int
    var beats: Int
    /// Total whole beats remaining (rounded up, so "1 beat" reads until the beat lands).
    var totalBeats: Int
}

/// One spoken count before a cue: say `word` at track time `time`.
struct SpokenCount: Equatable {
    var word: String
    var time: TimeInterval
}

/// A role's countdown at one playhead. Pure: build a new one per display frame.
struct CountdownModel: Equatable {
    var window: CrewLaneWindow
    var playhead: TimeInterval
    /// Seconds to the next cue (nil when the role has no more cues).
    var secondsToNext: TimeInterval?
    /// Bars/beats to the next cue, when the track has a beat grid.
    var barsBeatsToNext: BarsBeats?
    /// 0 at the previous cue of this role (or track start), 1 at the next cue. For a countdown bar.
    var progress: Double
    /// When to speak "3", "2", "1" before the next cue (seconds, or on beats with a grid).
    var spoken: [SpokenCount]

    /// - Parameters:
    ///   - cues: all cues of the track (any lanes); filtered to the role here.
    ///   - countFrom: how many counts to speak (3 = "3, 2, 1").
    ///   - barWindow: a countdown bar covers at most this many seconds (long gaps start the bar late).
    init(role: CrewRole, cues: [CrewCue], playhead: TimeInterval, grid: BeatGrid? = nil,
         countFrom: Int = 3, barWindow: TimeInterval = 10) {
        self.init(sortedRoleCues: CrewLaneFilter.cues(for: role, in: cues), playhead: playhead, grid: grid,
                  countFrom: countFrom, barWindow: barWindow)
    }

    init(sortedRoleCues mine: [CrewCue], playhead: TimeInterval, grid: BeatGrid? = nil,
         countFrom: Int = 3, barWindow: TimeInterval = 10) {
        let w = CrewLaneFilter.window(sortedCues: mine, at: playhead)
        window = w
        self.playhead = playhead
        secondsToNext = w.untilNext
        guard let next = w.next else {
            barsBeatsToNext = nil; progress = w.now == nil ? 0 : 1; spoken = []
            return
        }
        barsBeatsToNext = grid.map { Self.barsBeats(from: playhead, to: next.time, grid: $0) }
        let from = max(w.now?.time ?? 0, next.time - max(0.1, barWindow))
        let span = next.time - from
        progress = span > 0 ? min(1, max(0, (playhead - from) / span)) : 1
        spoken = Self.schedule(before: next.time, grid: grid, countFrom: countFrom)
    }

    static func barsBeats(from t: TimeInterval, to target: TimeInterval, grid: BeatGrid) -> BarsBeats {
        let remaining = max(0, grid.beatPosition(at: target) - grid.beatPosition(at: t))
        let total = Int((remaining - 1e-6).rounded(.up))
        let bpb = max(1, grid.beatsPerBar)
        let whole = max(0, total)
        return BarsBeats(bars: whole / bpb, beats: whole % bpb, totalBeats: whole)
    }

    /// "3", "2", "1" one second (or one beat, with a grid) apart, ending one step before `cue`.
    static func schedule(before cue: TimeInterval, grid: BeatGrid?, countFrom: Int = 3) -> [SpokenCount] {
        guard countFrom > 0 else { return [] }
        let step = grid?.beatLength ?? 1
        return (1...countFrom).reversed().map { n in SpokenCount(word: String(n), time: cue - Double(n) * step) }
    }
}

// MARK: - Speech (protocol only; the real voice reuses the studio voices later)

protocol CrewSpeaker: AnyObject {
    func speak(_ word: String)
}

/// Says nothing. Records what it was asked to say (tests, previews).
final class SilentCrewSpeaker: CrewSpeaker {
    private(set) var spoken: [String] = []
    func speak(_ word: String) { spoken.append(word) }
}

/// Decides which counts to speak as the playhead moves. Pure apart from the speaker call.
struct CountdownCaller {
    private var last: TimeInterval?

    /// Counts whose time falls in (previous playhead, playhead]. A backwards move or a jump
    /// longer than `maxStep` (a seek) speaks nothing, like `CueTriggerClock.crossed`.
    mutating func advance(to playhead: TimeInterval, schedule: [SpokenCount], maxStep: TimeInterval = 0.5) -> [SpokenCount] {
        defer { last = playhead }
        guard let prev = last, playhead > prev, playhead - prev < maxStep else { return [] }
        return schedule.filter { $0.time > prev && $0.time <= playhead }
    }

    mutating func advance(to playhead: TimeInterval, schedule: [SpokenCount], speaker: CrewSpeaker) {
        for c in advance(to: playhead, schedule: schedule) { speaker.speak(c.word) }
    }

    mutating func reset() { last = nil }
}
