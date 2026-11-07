import Foundation

/// Shot size presets. The stored field is free text so a director can write anything; these
/// are what a picker would offer.
enum ShotSize: String, CaseIterable, Identifiable {
    case ews = "EWS", ws = "WS", mws = "MWS", ms = "MS", mcu = "MCU", cu = "CU", ecu = "ECU"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ews: "Extreme wide"; case .ws: "Wide"; case .mws: "Medium wide"; case .ms: "Medium"
        case .mcu: "Medium close-up"; case .cu: "Close-up"; case .ecu: "Extreme close-up"
        }
    }
}

/// One line of a shotlist.
struct ShotRow: Equatable, Identifiable {
    var id: UUID
    /// 1-based order within its lane.
    var index: Int
    var laneID: UUID
    var time: TimeInterval
    /// Seconds to the next cut in the same lane; nil when the shot doesn't hold, or it is the
    /// last shot and the track length isn't known.
    var duration: TimeInterval?
    var camera: Int?
    var shotNumber: String
    var shotSize: String
    var name: String
    var note: String

    /// The shot number as printed: the typed one, else the position.
    var displayNumber: String { shotNumber.isEmpty ? String(index) : shotNumber }
}

enum ShotListBuilder {
    /// Shot rows for `cues`, optionally limited to `lanes`. Each lane is timed on its own: a
    /// shot runs to the next cut in its lane; the last held shot runs to `trackDuration`.
    /// Rows come back time-ordered across all lanes.
    static func rows(from cues: [CrewCue], lanes: Set<UUID>? = nil, trackDuration: TimeInterval? = nil) -> [ShotRow] {
        let picked = cues.filter { lanes?.contains($0.laneID) ?? true }
        var out: [ShotRow] = []
        for (lane, laneCues) in Dictionary(grouping: picked, by: \.laneID) {
            let sorted = laneCues.sorted(by: CrewCue.timeOrder)
            for (i, c) in sorted.enumerated() {
                var duration: TimeInterval?
                if c.holdUntilNext {
                    // Next cut = next cue in the lane at a later time (stacked cues at the same time don't end it).
                    if let next = sorted[(i + 1)...].first(where: { $0.time > c.time }) {
                        duration = next.time - c.time
                    } else if let end = trackDuration {
                        duration = max(0, end - c.time)
                    }
                }
                out.append(ShotRow(id: c.id, index: i + 1, laneID: lane, time: c.time, duration: duration,
                                   camera: c.camera, shotNumber: c.shotNumber, shotSize: c.shotSize,
                                   name: c.name, note: c.shotNote))
            }
        }
        return out.sorted { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
    }

    /// Total on-air seconds per camera across `rows` (shots without a duration count 0).
    static func cameraTotals(_ rows: [ShotRow]) -> [Int: TimeInterval] {
        var t: [Int: TimeInterval] = [:]
        for r in rows { if let c = r.camera { t[c, default: 0] += r.duration ?? 0 } }
        return t
    }

    /// Shot, Camera, Size, Timecode, Track time, Duration, Name, Note. CRLF, quoted text fields.
    static func csv(_ rows: [ShotRow], clock: CuePointClock) -> String {
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var out = ["Shot,Camera,Size,Timecode,Track time,Duration,Name,Note"]
        for r in rows {
            out.append([q(r.displayNumber), r.camera.map(String.init) ?? "", q(r.shotSize),
                        clock.timecode(at: r.time).description, clock.trackTime(r.time).description,
                        r.duration.map { String(format: "%.3f", $0) } ?? "", q(r.name), q(r.note)].joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    static func csvFileName(trackName: String) -> String { "\(CuePointExport.safe(trackName)) shotlist.csv" }
}
