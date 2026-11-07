import Foundation

/// How a crew device is tracking the show.
enum FollowState: Equatable {
    /// LTC (or the master's clock) is arriving; the playhead follows it.
    case following
    /// LTC stopped at `since` (host time); the playhead keeps running on its own until the
    /// freewheel limit, then the state moves to `.lost`.
    case freewheel(since: TimeInterval)
    /// No timecode for longer than the freewheel limit. The playhead holds where it stopped.
    case lost
    /// The operator steps cue to cue by hand; `index` is the cue the playhead sits on (-1 =
    /// before the first cue). LTC coming back doesn't take over until `resumeFollowing()`.
    case manual(index: Int)

    var label: String {
        switch self {
        case .following: "Following"
        case .freewheel: "Freewheel"
        case .lost: "Timecode lost"
        case .manual: "Manual"
        }
    }
}

/// Pure follow state machine. Feed it timecode frames (`ltc`) and periodic `tick`s with a
/// monotonic host time; read `playhead(at:)`. No clocks are read inside.
struct FollowMachine: Equatable {
    /// Gap after the last frame before freewheel starts (a few frames; LTC frames arrive every 33–42 ms).
    var dropoutAfter: TimeInterval = 0.15
    /// How long freewheel runs before giving up (configurable per show).
    var freewheelLimit: TimeInterval = 2
    /// Operator offset added to the followed position (+ = cues earlier).
    private(set) var nudge: TimeInterval = 0

    private(set) var state: FollowState = .lost
    /// Last timecode frame: track time and the host time it was read.
    private(set) var lastFrame: (trackTime: TimeInterval, host: TimeInterval)?
    /// Where the playhead stopped when timecode was lost (track time, nudge excluded).
    private(set) var heldPosition: TimeInterval = 0
    /// True while frames are arriving, whatever the state (manual mode still watches LTC).
    private(set) var ltcPresent = false

    init(dropoutAfter: TimeInterval = 0.15, freewheelLimit: TimeInterval = 2) {
        self.dropoutAfter = dropoutAfter; self.freewheelLimit = freewheelLimit
    }

    static func == (a: FollowMachine, b: FollowMachine) -> Bool {
        a.state == b.state && a.nudge == b.nudge && a.heldPosition == b.heldPosition && a.ltcPresent == b.ltcPresent
            && a.lastFrame?.trackTime == b.lastFrame?.trackTime && a.lastFrame?.host == b.lastFrame?.host
            && a.dropoutAfter == b.dropoutAfter && a.freewheelLimit == b.freewheelLimit
    }

    // MARK: Inputs

    /// A decoded timecode frame: the show is at `trackTime` at host time `host`.
    mutating func ltc(trackTime: TimeInterval, host: TimeInterval) {
        lastFrame = (trackTime, host)
        ltcPresent = true
        switch state {
        case .following, .freewheel, .lost: state = .following
        case .manual: break
        }
    }

    /// Call regularly (each display frame or timer tick) so dropouts are noticed.
    mutating func tick(host: TimeInterval) {
        guard let f = lastFrame else { return }
        let gap = host - f.host
        if gap > dropoutAfter { ltcPresent = false }
        switch state {
        case .following where gap > dropoutAfter:
            state = .freewheel(since: f.host)
            fallthrough
        case .freewheel:
            if gap > dropoutAfter + freewheelLimit {
                heldPosition = f.trackTime + (dropoutAfter + freewheelLimit)
                state = .lost
            }
        default: break
        }
    }

    /// Operator: step to the next / previous cue in `cueTimes` (sorted). From following or
    /// freewheel this starts at the cue the playhead is in.
    mutating func step(_ direction: Int, cueTimes: [TimeInterval], host: TimeInterval) {
        let current: Int
        if case .manual(let i) = state { current = i } else {
            let p = rawPosition(at: host)
            current = (cueTimes.lastIndex { $0 <= p + 1e-9 }) ?? -1
        }
        let next = min(max(-1, current + (direction >= 0 ? 1 : -1)), cueTimes.count - 1)
        state = .manual(index: next)
        heldPosition = next >= 0 ? cueTimes[next] : 0
    }

    /// Operator: hand control back to timecode. Following if frames are arriving, else lost.
    mutating func resumeFollowing(host: TimeInterval) {
        state = ltcPresent ? .following : .lost
        tick(host: host)
    }

    mutating func nudge(by delta: TimeInterval) { nudge += delta }
    mutating func resetNudge() { nudge = 0 }

    // MARK: Output

    /// The playhead in track seconds at host time `host`, nudge included.
    func playhead(at host: TimeInterval) -> TimeInterval { rawPosition(at: host) + nudge }

    private func rawPosition(at host: TimeInterval) -> TimeInterval {
        switch state {
        case .following, .freewheel:
            guard let f = lastFrame else { return heldPosition }
            // Freewheel = keep running at play speed from the last frame (capped at the limit).
            let run = min(max(0, host - f.host), dropoutAfter + freewheelLimit)
            return f.trackTime + run
        case .lost, .manual:
            return heldPosition
        }
    }
}
