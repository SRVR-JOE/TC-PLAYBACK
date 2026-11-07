import Foundation

/// Resolved view of a track's points against the cue types: each point's type, colour and
/// displayed cue number. Built once per change and shared by the timeline, list and exports.
struct CuePointIndex {
    let types: [CuePointType]
    private let typeByID: [UUID: CuePointType]
    private let defaultType: CuePointType
    /// 1-based position of each point within its own type (by time).
    private let position: [UUID: Int]
    private let cueIDs: [UUID: String]

    init(points: [CuePoint], types: [CuePointType]) {
        self.types = types
        var byID: [UUID: CuePointType] = [:]
        for t in types { byID[t.id] = t }
        typeByID = byID
        let def = byID[CuePointType.defaultID] ?? CuePointType.defaults[0]
        defaultType = def
        var pos: [UUID: Int] = [:], counts: [UUID: Int] = [:], ids: [UUID: String] = [:]
        for p in points.sorted(by: { $0.time < $1.time }) {
            let tid = p.typeID.flatMap { byID[$0]?.id } ?? def.id
            counts[tid, default: 0] += 1
            pos[p.id] = counts[tid]
            ids[p.id] = p.cueID
        }
        position = pos
        cueIDs = ids
    }

    func type(of p: CuePoint) -> CuePointType { type(id: p.typeID) }
    func type(id: UUID?) -> CuePointType { id.flatMap { typeByID[$0] } ?? defaultType }
    /// Mark colour if set, else the type's colour.
    func colorHex(of p: CuePoint) -> String { p.colorHex ?? type(of: p).colorHex }
    func position(of p: CuePoint) -> Int { position[p.id] ?? 1 }
    /// What the console shows: the typed cue number, else the position within the type.
    func number(of p: CuePoint) -> String {
        let id = p.cueID.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? String(position(of: p)) : id
    }
}

/// Cue-number helpers: renumber a type 1, 2, 3…, and pick a point number for a mark dropped
/// between two numbered cues (10 and 11 → 10.5), which every console accepts.
enum CuePointNumbering {
    /// Sequential numbers for `times` in time order ("1", "2", …), keyed by index into `times`.
    static func renumbered(count: Int, startingAt first: Int = 1) -> [String] {
        (0..<count).map { String(first + $0) }
    }

    /// A number strictly between `previous` and `next` cue numbers. Returns "" when neither
    /// neighbour is numeric (the type isn't numbered yet, so position numbering still applies).
    static func between(_ previous: String?, _ next: String?) -> String {
        let p = previous.flatMap(value), n = next.flatMap(value)
        switch (p, n) {
        case (nil, nil): return ""
        case (let a?, nil): return format(a.rounded(.down) + 1)
        case (nil, let b?): return between(0, b) ?? ""
        case (let a?, let b?): return between(a, b) ?? ""
        }
    }

    private static func between(_ a: Double, _ b: Double) -> String? {
        guard a < b else { return nil }
        let whole = a.rounded(.down) + 1
        if whole < b { return format(whole) }
        for places in 1...3 {
            let scale = pow(10, Double(places))
            let mid = ((a + b) / 2 * scale).rounded() / scale
            if mid > a, mid < b { return format(mid) }
            // Rounding landed on an end: step one unit in from `a`.
            let up = ((a * scale).rounded(.down) + 1) / scale
            if up > a, up < b { return format(up) }
        }
        return nil
    }

    static func value(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Moving several marks at once while keeping their spacing.
enum CuePointSelectionMath {
    /// Clamps `delta` so every time stays inside 0…duration (the group moves as one block).
    static func clampedDelta(times: [TimeInterval], by delta: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard let lo = times.min(), let hi = times.max() else { return 0 }
        return min(max(delta, -lo), max(0, duration - hi))
    }

    /// New times after shifting by `delta` (clamped), each snapped to the frame grid.
    static func shifted(_ times: [TimeInterval], by delta: TimeInterval, duration: TimeInterval, fps: Double) -> [TimeInterval] {
        let d = clampedDelta(times: times, by: delta, duration: duration)
        return times.map { snap($0 + d, fps: fps, duration: duration) }
    }

    /// Shift so the earliest time lands on `target`.
    static func movingFirst(_ times: [TimeInterval], to target: TimeInterval, duration: TimeInterval, fps: Double) -> [TimeInterval] {
        guard let lo = times.min() else { return times }
        return shifted(times, by: target - lo, duration: duration, fps: fps)
    }

    static func snap(_ t: TimeInterval, fps: Double, duration: TimeInterval) -> TimeInterval {
        FrameGrid.snap(t, fps: fps, duration: duration)
    }
}

extension CuePointRow {
    /// Export rows for a track: sorted by time, `number` = position within the type, cue number,
    /// type, resolved colour and fades ("+" runs to the next point of the same type).
    static func rows(for points: [CuePoint], index: CuePointIndex) -> [CuePointRow] {
        let sorted = points.sorted { $0.time < $1.time }
        return sorted.enumerated().map { i, p in
            let t = index.type(of: p)
            let next = sorted[(i + 1)...].first(where: { index.type(of: $0).id == t.id })?.time
            let fade = CueFade.resolve(p.fade, at: p.time, nextSameType: next)
            return CuePointRow(number: index.position(of: p), name: p.name, time: p.time, colorHex: index.colorHex(of: p),
                               cueID: p.cueID.trimmingCharacters(in: .whitespaces), typeName: t.name, typeID: t.id,
                               fadeIn: fade.in, fadeOut: fade.out)
        }
    }
}
