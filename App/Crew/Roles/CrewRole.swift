import Foundation
import Observation

/// One crew position that follows the show: "Cam 3", "Lighting", "SFX". A role watches one or
/// more cue lanes (`CuePointType` ids); a camera role can narrow that to its own camera number.
struct CrewRole: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case camera, lighting, video, audio, sfx, stage, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .camera: "Camera"; case .lighting: "Lighting"; case .video: "Video"; case .audio: "Audio"
            case .sfx: "SFX"; case .stage: "Stage"; case .custom: "Custom"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var kind: Kind
    /// Camera number for camera roles. When set, only cues with this camera match.
    var cameraNumber: Int? = nil
    var colorHex: String
    /// Cue lanes this role follows. Empty + a camera number = that camera in any lane.
    var laneIDs: [UUID] = []

    /// True when `cue` is one of this role's cues.
    func matches(_ cue: CrewCue) -> Bool {
        let laneOK = laneIDs.isEmpty ? cameraNumber != nil : laneIDs.contains(cue.laneID)
        guard laneOK else { return false }
        if let n = cameraNumber { return cue.camera == n }
        return true
    }

    // Tolerant decoding so roles saved by older builds keep loading.
    private enum CodingKeys: String, CodingKey { case id, name, kind, cameraNumber, colorHex, laneIDs }
    init(id: UUID = UUID(), name: String, kind: Kind, cameraNumber: Int? = nil, colorHex: String, laneIDs: [UUID] = []) {
        self.id = id; self.name = name; self.kind = kind; self.cameraNumber = cameraNumber
        self.colorHex = colorHex; self.laneIDs = laneIDs
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .custom
        cameraNumber = try c.decodeIfPresent(Int.self, forKey: .cameraNumber)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? CuePointColor.white.rawValue
        laneIDs = try c.decodeIfPresent([UUID].self, forKey: .laneIDs) ?? []
    }
}

/// What a role sees at a playhead: the cue it is in, the next one, and the one after.
struct CrewLaneWindow: Equatable {
    var now: CrewCue?
    var next: CrewCue?
    var after: CrewCue?
    /// Seconds until `next` (nil when there is no next cue).
    var untilNext: TimeInterval?
}

enum CrewLaneFilter {
    /// The role's cues, time-ordered.
    static func cues(for role: CrewRole, in cues: [CrewCue]) -> [CrewCue] {
        cues.filter(role.matches).sorted(by: CrewCue.timeOrder)
    }

    /// Now / next / next+1 for `role` at `playhead`. A cue exactly at the playhead is "now".
    static func window(for role: CrewRole, cues all: [CrewCue], at playhead: TimeInterval) -> CrewLaneWindow {
        window(sortedCues: cues(for: role, in: all), at: playhead)
    }

    /// Same, for cues already filtered and sorted (the countdown engine calls this per frame).
    static func window(sortedCues mine: [CrewCue], at playhead: TimeInterval) -> CrewLaneWindow {
        // First cue strictly after the playhead (binary search: lanes can hold thousands of shots).
        var lo = 0, hi = mine.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if mine[mid].time <= playhead { lo = mid + 1 } else { hi = mid }
        }
        let now = lo > 0 ? mine[lo - 1] : nil
        let next = lo < mine.count ? mine[lo] : nil
        let after = lo + 1 < mine.count ? mine[lo + 1] : nil
        return CrewLaneWindow(now: now, next: next, after: after, untilNext: next.map { $0.time - playhead })
    }

    /// Lanes a fresh role of `kind` should follow, matched by type name against the current types.
    static func suggestedLanes(for kind: CrewRole.Kind, types: [CuePointType]) -> [UUID] {
        let words: [String]
        switch kind {
        case .camera: words = ["cam", "shot"]
        case .lighting: words = ["light", "lx"]
        case .video: words = ["video", "vid", "media"]
        case .audio: words = ["audio", "sound", "snd"]
        case .sfx: words = ["fx", "pyro", "special"]
        case .stage: words = ["stage", "deck", "auto"]
        case .custom: words = []
        }
        return types.filter { t in words.contains { t.name.lowercased().contains($0) } }.map(\.id)
    }
}

/// App-wide crew roles, JSON in UserDefaults (same pattern as `CuePointTypeStore`).
@Observable
final class CrewRoleStore {
    static let key = "crew.roles"

    private(set) var roles: [CrewRole]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([CrewRole].self, from: data) {
            roles = saved
        } else {
            roles = []
        }
    }

    func role(_ id: UUID?) -> CrewRole? { id.flatMap { id in roles.first { $0.id == id } } }

    @discardableResult
    func add(_ role: CrewRole) -> CrewRole { roles.append(role); persist(); return role }

    func update(_ role: CrewRole) {
        guard let i = roles.firstIndex(where: { $0.id == role.id }) else { return }
        roles[i] = role; persist()
    }

    func delete(_ id: UUID) { roles.removeAll { $0.id == id }; persist() }

    func replaceAll(_ list: [CrewRole]) { roles = list; persist() }

    /// Drops lane ids that no longer exist (a cue type was deleted).
    func prune(validLaneIDs: Set<UUID>) {
        var changed = false
        for i in roles.indices {
            let kept = roles[i].laneIDs.filter(validLaneIDs.contains)
            if kept != roles[i].laneIDs { roles[i].laneIDs = kept; changed = true }
        }
        if changed { persist() }
    }

    /// A starter set: four cameras on the shot lane, plus lighting / video / SFX on their lanes.
    static func starterRoles(types: [CuePointType], cameras: Int = 4) -> [CrewRole] {
        let palette = CuePointColor.allCases.map(\.rawValue)
        var out: [CrewRole] = []
        let camLanes = CrewLaneFilter.suggestedLanes(for: .camera, types: types)
        for n in 1...max(1, cameras) {
            out.append(CrewRole(name: "Cam \(n)", kind: .camera, cameraNumber: n,
                                colorHex: palette[(n - 1) % palette.count], laneIDs: camLanes))
        }
        for (k, name) in [(CrewRole.Kind.lighting, "Lighting"), (.video, "Video"), (.sfx, "SFX")] {
            out.append(CrewRole(name: name, kind: k, colorHex: palette[out.count % palette.count],
                                laneIDs: CrewLaneFilter.suggestedLanes(for: k, types: types)))
        }
        return out
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(roles) { defaults.set(data, forKey: Self.key) }
    }
}
