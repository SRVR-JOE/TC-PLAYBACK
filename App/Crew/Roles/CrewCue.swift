import Foundation

/// Plain value copy of a cue point as the crew framework sees it: lane, time, and the shot
/// script fields. Codable so the master can ship a track's cue list to followers. Built from a
/// `CuePoint` (SwiftData) or a `CuePointRow` (export rows); nothing here touches SwiftData.
struct CrewCue: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    /// Seconds from the start of the audio file.
    var time: TimeInterval
    var name: String
    /// Cue type (lane) id, already resolved: never nil, unknown ids map to the default type.
    var laneID: UUID
    /// Console cue number as displayed ("1", "2.5"); empty when the lane isn't numbered.
    var cueID: String = ""
    var colorHex: String? = nil
    // Shot script
    var camera: Int? = nil
    var shotNumber: String = ""
    var shotSize: String = ""
    var shotNote: String = ""
    var holdUntilNext: Bool = true

    var isShot: Bool { camera != nil || !shotNumber.isEmpty || !shotSize.isEmpty }
}

extension CrewCue {
    /// From the stored model, with the lane resolved through the index.
    init(point p: CuePoint, index: CuePointIndex) {
        self.init(id: p.id, time: p.time, name: p.name, laneID: index.type(of: p).id,
                  cueID: index.number(of: p), colorHex: index.colorHex(of: p),
                  camera: p.camera, shotNumber: p.shotNumber, shotSize: p.shotSize,
                  shotNote: p.shotNote, holdUntilNext: p.holdUntilNext)
    }

    /// From an export row (no shot fields there; they stay at their defaults).
    init(row r: CuePointRow, id: UUID = UUID()) {
        self.init(id: id, time: r.time, name: r.name, laneID: r.typeID ?? CuePointType.defaultID,
                  cueID: r.consoleCueID, colorHex: r.colorHex)
    }

    /// Every point of a track, time-ordered.
    static func cues(for points: [CuePoint], types: [CuePointType]) -> [CrewCue] {
        let index = CuePointIndex(points: points, types: types)
        return points.map { CrewCue(point: $0, index: index) }.sorted(by: CrewCue.timeOrder)
    }

    /// Time, then id, so equal times sort the same everywhere (master and follower).
    static func timeOrder(_ a: CrewCue, _ b: CrewCue) -> Bool {
        a.time != b.time ? a.time < b.time : a.id.uuidString < b.id.uuidString
    }
}
