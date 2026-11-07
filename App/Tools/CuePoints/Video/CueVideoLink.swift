import Foundation
import TCKit

/// A recording (phone or show video) attached to one track, so cue marks can be made while
/// watching it. The video follows the track: video time = track time − offset.
struct CueVideoLink: Codable, Equatable {
    /// File name inside `CueVideoStore.directory`.
    var fileName: String
    /// Seconds. Positive = the video starts after the track does.
    var offset: TimeInterval = 0
    /// Video seconds per track second. Kept at 1.0 for now; stored so drift correction can come later.
    var rate: Double = 1.0
    /// The name the file had when it was chosen (shown in the panel header).
    var displayName: String = ""

    init(fileName: String, offset: TimeInterval = 0, rate: Double = 1.0, displayName: String = "") {
        self.fileName = fileName; self.offset = offset; self.rate = rate; self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        offset = try c.decodeIfPresent(TimeInterval.self, forKey: .offset) ?? 0
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }

    /// Where in the video the track time `t` lands.
    func videoTime(atTrackTime t: TimeInterval) -> TimeInterval { (t - offset) * rate }
    /// The track time that shows video time `v`.
    func trackTime(atVideoTime v: TimeInterval) -> TimeInterval { v / rate + offset }

    /// The offset that puts video time `v` at track time `t` ("Line up here").
    static func offset(trackTime t: TimeInterval, videoTime v: TimeInterval) -> TimeInterval { t - v }

    var title: String { displayName.isEmpty ? fileName : displayName }
}

/// Per-track links in UserDefaults ("cuePoints.video.<trackID>"); files in Application Support/CueVideos.
enum CueVideoStore {
    static func key(_ trackID: UUID) -> String { "cuePoints.video.\(trackID.uuidString)" }

    static func load(_ trackID: UUID, defaults: UserDefaults = .standard) -> CueVideoLink? {
        guard let d = defaults.data(forKey: key(trackID)) else { return nil }
        return try? JSONDecoder().decode(CueVideoLink.self, from: d)
    }

    static func save(_ link: CueVideoLink, for trackID: UUID, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(link) { defaults.set(d, forKey: key(trackID)) }
    }

    /// Forgets the link and deletes the copied file (unless another track still uses it).
    static func remove(_ trackID: UUID, defaults: UserDefaults = .standard, deleteFile: Bool = true) {
        let link = load(trackID, defaults: defaults)
        defaults.removeObject(forKey: key(trackID))
        if deleteFile, let link { try? FileManager.default.removeItem(at: url(for: link)) }
    }

    static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "CueVideos", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var u = url; var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v)
        }
        return url
    }

    static func url(for link: CueVideoLink) -> URL { directory.appending(path: link.fileName) }

    /// A fresh, unique file name for a video copied in for `trackID`.
    static func newFileName(for trackID: UUID, ext: String) -> String {
        let e = ext.isEmpty ? "mov" : ext.lowercased()
        return "\(trackID.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).\(e)"
    }
}

/// Offset wording for the panel and the sync sheet: "+37.250 s" and "+37 s 8 f".
enum CueVideoOffsetFormat {
    static func seconds(_ o: TimeInterval) -> String {
        String(format: "%@%.3f s", o < 0 ? "−" : "+", abs(o))
    }

    /// Whole seconds and frames at `rate`, signed, rounded to the nearest frame.
    static func framesText(_ o: TimeInterval, rate: FrameRate) -> String {
        let fps = rate.fps
        let total = Int((abs(o) * fps).rounded())
        let perSec = max(1, rate.nominalFPS)
        let s = total / perSec, f = total % perSec
        let sign = total == 0 ? "" : (o < 0 ? "−" : "+")
        return "\(sign)\(s) s \(f) f"
    }

    /// Parses "37.25", "-1.5", "+37 s", or a signed timecode "-00:00:37:08" / "37:08" (s:f).
    static func parse(_ text: String, rate: FrameRate) -> TimeInterval? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        t = t.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        if let v = Double(t) { return sign * v }
        let parts = t.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! }
        let frames = p.last!
        var secs = 0
        for v in p.dropLast() { secs = secs * 60 + v }
        return sign * (Double(secs) + Double(frames) / rate.fps)
    }
}
