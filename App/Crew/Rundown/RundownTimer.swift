import Foundation

/// When an act actually ran, in show-clock seconds (seconds since show start).
struct ActActual: Codable, Equatable {
    var start: TimeInterval
    /// nil while the act is running.
    var end: TimeInterval?
}

/// Planned vs actual for one act.
struct ActTiming: Equatable, Identifiable {
    enum State: Equatable { case pending, running, done, skipped }
    var id: UUID
    var state: State
    /// Where the plan puts this act (explicit start, else straight after the previous act).
    var plannedStart: TimeInterval
    var plannedDuration: TimeInterval
    var actualStart: TimeInterval?
    /// Done: real length. Running: elapsed so far.
    var actualDuration: TimeInterval?
    /// Best guess start: actual if it started, else after the projected end of the act before.
    var projectedStart: TimeInterval
    var projectedEnd: TimeInterval
    /// actual − planned length (+ = over). Done acts only; nil otherwise.
    var overUnder: TimeInterval?
    /// actual/projected start − planned start (+ = late).
    var startDrift: TimeInterval
}

struct RundownStatus: Equatable {
    var acts: [ActTiming]
    /// Seconds since the first act started (0 before the show).
    var runningTime: TimeInterval
    var plannedEnd: TimeInterval
    var projectedEnd: TimeInterval
    /// projected − planned end (+ = the show will run over).
    var overUnder: TimeInterval { projectedEnd - plannedEnd }
    var current: ActTiming? { acts.first { $0.state == .running } }
    var next: ActTiming? { acts.first { $0.state == .pending } }
}

/// Pure planned-vs-actual maths. Skipped acts take no time in either the plan or the
/// projection; reordering changes both because starts chain in running order.
enum RundownTimer {
    static func status(_ rundown: Rundown, actuals: [UUID: ActActual], now: TimeInterval) -> RundownStatus {
        var out: [ActTiming] = []
        var plannedCursor: TimeInterval = 0
        var projectedCursor: TimeInterval = 0
        var firstStart: TimeInterval?
        var firstPendingSeen = false

        for act in rundown.acts {
            let actual = actuals[act.id]
            if act.skip && actual == nil {
                out.append(ActTiming(id: act.id, state: .skipped, plannedStart: plannedCursor, plannedDuration: 0,
                                     actualStart: nil, actualDuration: nil, projectedStart: projectedCursor,
                                     projectedEnd: projectedCursor, overUnder: nil, startDrift: 0))
                continue
            }
            let pStart = act.plannedStart ?? plannedCursor
            let pDur = max(0, act.plannedDuration)
            plannedCursor = pStart + pDur

            let state: ActTiming.State
            let start: TimeInterval
            var actualDuration: TimeInterval?
            var projectedDuration = pDur
            var overUnder: TimeInterval?
            if let a = actual {
                start = a.start
                firstStart = min(firstStart ?? a.start, a.start)
                if let e = a.end {
                    state = .done
                    actualDuration = max(0, e - a.start)
                    projectedDuration = actualDuration!
                    overUnder = actualDuration! - pDur
                } else {
                    state = .running
                    actualDuration = max(0, now - a.start)
                    projectedDuration = max(pDur, actualDuration!)
                }
            } else {
                state = .pending
                // Not before the act ahead ends, nor before its explicit planned start. Once the
                // show is running, the first pending act can't start in the past either.
                var s = max(projectedCursor, act.plannedStart ?? projectedCursor)
                if firstStart != nil, !firstPendingSeen { s = max(s, now) }
                firstPendingSeen = true
                start = s
            }
            let end = start + projectedDuration
            projectedCursor = end
            out.append(ActTiming(id: act.id, state: state, plannedStart: pStart, plannedDuration: pDur,
                                 actualStart: actual?.start, actualDuration: actualDuration, projectedStart: start,
                                 projectedEnd: end, overUnder: overUnder, startDrift: start - pStart))
        }
        return RundownStatus(acts: out, runningTime: firstStart.map { max(0, now - $0) } ?? 0,
                             plannedEnd: plannedCursor, projectedEnd: projectedCursor)
    }
}
