import Foundation
import CryptoKit
import SwiftData

/// Analyses saved per track in Application Support/SongAnalysis, keyed by the track id, a hash of
/// the file (size, date, first and last 256 KB), the LTC side and the analyser version, so a
/// replaced file or a new analyser redoes the work. Rejected suggestions are kept with it.
enum SongAnalysisCache {
    struct Entry: Codable {
        var analysis: SongAnalysis
        var rejected: Set<UUID> = []
        var accepted: Set<UUID> = []
    }

    static var directory: URL {
        let d = URL.applicationSupportDirectory.appending(path: "SongAnalysis", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func key(url: URL, trackID: UUID, ltcChannel: Int?) -> String {
        var h = SHA256()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        h.update(data: Data("\(trackID.uuidString)|\(size)|\(date)|\(ltcChannel ?? -1)|v\(SongAnalyzer.version)".utf8))
        if let f = try? FileHandle(forReadingFrom: url) {
            let chunk = 256 * 1024
            if let head = try? f.read(upToCount: chunk) { h.update(data: head) }
            if size > Int64(chunk) * 2, (try? f.seek(toOffset: UInt64(size) - UInt64(chunk))) != nil,
               let tail = try? f.read(upToCount: chunk) { h.update(data: tail) }
            try? f.close()
        }
        let digest = h.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(trackID.uuidString)-\(digest.prefix(16))"
    }

    static func file(_ key: String) -> URL { directory.appending(path: "\(key).json") }

    static func load(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(key)), let e = try? JSONDecoder().decode(Entry.self, from: data),
              e.analysis.version == SongAnalyzer.version else { return nil }
        return e
    }

    static func save(_ e: Entry, key: String) {
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(key), options: .atomic) }
    }

    /// Drops every cached analysis of `trackID` (all file versions).
    static func remove(trackID: UUID) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(trackID.uuidString) { try? FileManager.default.removeItem(at: f) }
    }
}

/// Turns accepted suggestions into cue points by the same rules as a live mark: frame-snapped
/// time, the suggested type (by name, else the default type), ripple cue numbers once a type has
/// typed numbers, and repeated labels numbered (song sections from 1).
enum MomentAcceptance {
    static func points(for moments: [SongMoment], trackID: UUID, existing: [CuePoint], types: [CuePointType],
                       fps: Double, duration: TimeInterval, numberRepeats: Bool) -> [CuePoint] {
        var all = existing
        var made: [CuePoint] = []
        let defaultType = types.first { $0.id == CuePointType.defaultID } ?? CuePointType.defaults[0]
        for m in moments.sorted(by: { $0.time < $1.time }) {
            let type = types.first { !$0.hidden && $0.name.caseInsensitiveCompare(m.cueTypeName) == .orderedSame } ?? defaultType
            let t = min(max(0, (m.time * fps).rounded() / fps), duration)
            let idx = CuePointIndex(points: all, types: types)
            let same = all.filter { idx.type(of: $0).id == type.id }
            // Accepting the same suggestion twice (or one already marked by hand) adds nothing.
            guard !same.contains(where: { abs($0.time - t) < 0.5 / fps }) else { continue }
            var cueID = ""
            if same.contains(where: { !$0.cueID.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let prev = same.last(where: { $0.time <= t }), next = same.first(where: { $0.time > t })
                cueID = CuePointNumbering.between(prev.map(idx.number(of:)), next.map(idx.number(of:)))
            }
            let p = CuePoint(trackID: trackID, time: t, name: name(for: m, existing: same.map(\.name), numberRepeats: numberRepeats))
            p.typeID = type.id == CuePointType.defaultID ? nil : type.id
            p.cueID = cueID
            all.append(p); made.append(p)
        }
        return made
    }

    /// The analyser's numbered section name when it's free in this type ("Chorus 2"), else the
    /// next free number; other labels follow "Number repeated labels".
    static func name(for m: SongMoment, existing: [String], numberRepeats: Bool) -> String {
        let label = m.label.trimmingCharacters(in: .whitespaces)
        let taken = { (n: String) in existing.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
        if m.kind == .section {
            if !taken(label) { return label }
            let base = label.split(separator: " ").dropLast().joined(separator: " ")
            return CueLabelNaming.numbered(base.isEmpty ? label : base, existing: existing)
        }
        guard numberRepeats else { return label }
        return CueLabelNaming.numbered(label, existing: existing)
    }
}
