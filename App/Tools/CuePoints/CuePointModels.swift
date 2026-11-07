import Foundation
import SwiftData
import TCKit

/// A named marker in a track ("Verse 1", "Drop", "Pyro"), made while listening and exported to
/// a disguise cue table, a grandMA3 timecode show, or CSV. Stored by track id (not a relationship)
/// so the frozen Track model doesn't change.
@Model
final class CuePoint {
    @Attribute(.unique) var id: UUID
    var trackID: UUID
    /// Seconds from the start of the audio file.
    var time: TimeInterval
    var name: String
    var colorHex: String?
    var createdAt: Date
    // CONTRACT (team build) — additive fields, defaults keep existing stores migrating.
    /// Cue type (lane) this point belongs to; nil = the default "Cue" type.
    var typeID: UUID? = nil
    /// Console cue number, free text ("1", "2.5", "101"). Empty = use the point's position.
    var cueID: String = ""
    /// Fade as typed: "" (default), "2" seconds, "+" (until the next point of the same type),
    /// "1/2" (split: 1 s up / 2 s down). Resolve with `CueFade.resolve`.
    var fade: String = ""
    /// Cue caller: what to say over comms for this mark ("Camera 3, push in slow"). Written once
    /// in the operator's language, translated per area. Empty = no spoken call for this mark.
    var callNote: String = ""

    init(trackID: UUID, time: TimeInterval, name: String, colorHex: String? = nil) {
        self.id = UUID(); self.trackID = trackID; self.time = time; self.name = name
        self.colorHex = colorHex; self.createdAt = .now
    }

    static func points(for trackID: UUID, in context: ModelContext) -> [CuePoint] {
        let d = FetchDescriptor<CuePoint>(predicate: #Predicate { $0.trackID == trackID }, sortBy: [SortDescriptor(\.time)])
        return (try? context.fetch(d)) ?? []
    }
}

/// Marker colours, flat and few (console-style).
enum CuePointColor: String, CaseIterable, Identifiable {
    case white = "#E8EAED", red = "#E5484D", amber = "#E5A50A", green = "#2FB85A", blue = "#3D8BFD", purple = "#9B6BFF"
    var id: String { rawValue }
    var label: String {
        switch self { case .white: "White"; case .red: "Red"; case .amber: "Amber"; case .green: "Green"; case .blue: "Blue"; case .purple: "Purple" }
    }
}

/// Where the track's time 0 sits on the timecode line, and at what rate.
struct CuePointClock: Equatable {
    var start: Timecode
    var rate: FrameRate { start.rate }

    func timecode(at t: TimeInterval) -> Timecode { start.adding(seconds: t) }

    /// "HH:MM:SS.FF" — the style disguise writes in its Track_Time / TC_Time columns.
    static func dotted(_ tc: Timecode) -> String {
        String(format: "%02d:%02d:%02d.%02d", tc.hours, tc.minutes, tc.seconds, tc.frames)
    }
    /// Track-relative time in frames at this rate, as a timecode from zero.
    func trackTime(_ t: TimeInterval) -> Timecode { Timecode(realSeconds: max(0, t), rate: rate) }

    /// Start from the track's LTC when it has one; otherwise a per-track saved value; else 01:00:00:00 @ 30.
    static func forTrack(_ track: Track) -> CuePointClock {
        if let s = UserDefaults.standard.string(forKey: key(track.id)), let rr = UserDefaults.standard.string(forKey: key(track.id) + ".rate"),
           let r = FrameRate(rawValue: rr), let tc = Timecode(string: s, rate: r) {
            return CuePointClock(start: tc)
        }
        if let tc = track.ltcStartTimecode { return CuePointClock(start: tc) }
        return CuePointClock(start: Timecode(hours: 1, rate: .fps30))
    }
    static func save(_ clock: CuePointClock, for track: Track) {
        UserDefaults.standard.set(clock.start.description, forKey: key(track.id))
        UserDefaults.standard.set(clock.rate.rawValue, forKey: key(track.id) + ".rate")
    }
    private static func key(_ id: UUID) -> String { "cuePointStart.\(id.uuidString)" }
}

/// Plain value copy of a point for exporting (no SwiftData).
struct CuePointRow: Equatable {
    var number: Int
    var name: String
    var time: TimeInterval
    var colorHex: String?
    // CONTRACT (team build) — additive, defaulted so existing call sites compile.
    /// Console cue number ("" → use `number`).
    var cueID: String = ""
    /// Cue type name ("Cue", "Lights", "Video", "Pyro"…), and its id.
    var typeName: String = "Cue"
    var typeID: UUID? = nil
    /// Resolved fade in seconds (nil = none / console default).
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil

    /// What consoles show as the cue number.
    var consoleCueID: String { cueID.isEmpty ? String(number) : cueID }
}

/// A cue type = a lane on the timeline and a group in exports (e.g. a MA3 sequence or a
/// disguise track). Stored as JSON in UserDefaults (`CuePointTypeStore`), app-wide.
struct CuePointType: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
    var hidden = false
    var locked = false
    /// MA3 sequence number this type fires (0 = unset). Used by the MA3 export.
    var ma3Sequence: Int = 0

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0E0")!
    static let defaults: [CuePointType] = [
        CuePointType(id: defaultID, name: "Cue", colorHex: CuePointColor.amber.rawValue, ma3Sequence: 1),
        CuePointType(name: "Lights", colorHex: CuePointColor.blue.rawValue, ma3Sequence: 2),
        CuePointType(name: "Video", colorHex: CuePointColor.green.rawValue, ma3Sequence: 3),
        CuePointType(name: "Special FX", colorHex: CuePointColor.red.rawValue, ma3Sequence: 4),
    ]
}

/// Fade syntax shared with CuePoints-style tools: "2" = 2 s, "+" = time until the next point
/// of the same type, "1/2" = 1 s in / 2 s out.
enum CueFade {
    static func resolve(_ text: String, at time: TimeInterval, nextSameType: TimeInterval?) -> (in: Double?, out: Double?) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return (nil, nil) }
        if t == "+" { let g = nextSameType.map { max(0, $0 - time) }; return (g, g) }
        let parts = t.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let a = parts[0], let b = parts[1] { return (a, b) }
        if let v = Double(t) { return (v, v) }
        return (nil, nil)
    }
}

// MARK: - Exporters

enum CuePointExport {
    struct DisguiseOptions: Equatable {
        /// disguise tracks count in beats; at 60 BPM a beat is one second (what d3 writes by default).
        var bpm: Double = 60
        /// Adds a TC tag at beat 0 with the track's start timecode, so the d3 track chases LTC.
        var tcTagAtStart = true
        /// Tags each point "CUE n" (else the note carries the name only).
        var cueTags = true
        /// Starts a new section at each point (lets the operator jump section to section).
        var sectionBreaks = true
    }

    /// disguise cue table: tab-separated, CRLF, header "Cue table for <track>", columns
    /// Beat · Tag · Note · Track_Time · TC_Time · Section_Break. Matches files written by Designer.
    /// Name the file "<d3 track name>_cue_table.txt" and drop it in <project>/objects/table.
    static func disguiseCueTable(trackName: String, rows: [CuePointRow], clock: CuePointClock,
                                 options: DisguiseOptions = .init()) -> String {
        var lines = ["Cue table for \(trackName)", "Beat\tTag\tNote\tTrack_Time\tTC_Time\tSection_Break"]
        func beat(_ t: TimeInterval) -> String { String(format: "%.5f", t * options.bpm / 60) }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        if options.tcTagAtStart {
            lines.append([beat(0), "TC \(clock.start.description)", "", CuePointClock.dotted(clock.trackTime(0)),
                          CuePointClock.dotted(clock.start), "1"].joined(separator: "\t"))
        }
        for r in rows.sorted(by: { $0.time < $1.time }) {
            // A point exactly at 0 shares beat 0 with the TC tag (stacked tags are allowed).
            let tag = options.cueTags ? "CUE \(r.number)" : ""
            lines.append([beat(r.time), tag, clean(r.name), CuePointClock.dotted(clock.trackTime(r.time)),
                          CuePointClock.dotted(clock.timecode(at: r.time)), options.sectionBreaks ? "1" : "0"]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\r\n")
    }

    static func disguiseFileName(trackName: String) -> String { "\(safe(trackName))_cue_table.txt" }

    /// grandMA3 timecode show that FIRES cues: a Marker track (visual only) plus one Track per cue
    /// type, targeting that type's sequence, with a `Goto` command event per point.
    ///
    /// Structure mirrors real/console-validated exports (see CuePointExport+More.swift for sources):
    /// `Timecode > TrackGroup > Track(Target) > TimeRange > CmdSubTrack > CmdEvent > RealtimeCmd`.
    /// Event `Time` is written in seconds (as MA writes it in XML; MA's internal RawTime is
    /// seconds x 2^24, see `ma3RawTime`). The console resolves Targets and `CueDestination` by NAME, so
    /// sequences must be named after the cue type and cues after the point; the cue-list macro
    /// (`grandMA3CueListMacro`) builds exactly that. Import with
    /// `Import Timecode <slot> "<file>"` from gma3_library/datapools/timecodes. Times are seconds
    /// from the track start; set the timecode object's offset/slot to the start TC.
    static func grandMA3Timecode(trackName: String, rows: [CuePointRow], clock: CuePointClock, duration: TimeInterval,
                                 types: [CuePointType] = []) -> String {
        let esc = ma3Escape
        func t(_ v: TimeInterval) -> String { String(format: "%.2f", max(0, v)) }
        func t3(_ v: TimeInterval) -> String { String(format: "%.3f", max(0, v)) }
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GMA3 DataVersion="\(ma3DataVersion)">
        \t<Timecode Name="\(esc(trackName))" Guid="\(guid())" Duration="\(t(duration))" LoopCount="0" TCSlot="-1" AutoStop="No" SwitchOff="Keep Playbacks" Goto="as Go">
        \t\t<TrackGroup Play="" Rec="">
        \t\t\t<MarkerTrack Name="Marker" Guid="\(guid())">

        """
        let sorted = rows.sorted(by: { $0.time < $1.time })
        for r in sorted {
            x += "\t\t\t\t<Marker Name=\"\(esc("\(r.number) \(r.name)"))\" Guid=\"\(guid())\" Time=\"\(t(r.time))\" />\n"
        }
        x += "\t\t\t</MarkerTrack>\n"
        for g in ma3Groups(rows: sorted, types: types) {
            let idx = max(0, g.sequence - 1)
            x += "\t\t\t<Track Name=\"\(esc(g.sequenceName))\" Guid=\"\(guid())\" Play=\"\" Rec=\"\" Target=\"ShowData.DataPools.Default.Sequences.\(esc(g.sequenceName))\">\n"
            x += "\t\t\t\t<TimeRange Guid=\"\(guid())\" Duration=\"To End\" Play=\"\" Rec=\"\" Start=\"0.000\">\n"
            x += "\t\t\t\t\t<CmdSubTrack>\n"
            for c in g.cues {
                x += "\t\t\t\t\t\t<CmdEvent Name=\"Goto\" Time=\"\(t3(c.row.time))\" CueDestination=\"\(esc(c.label))\">\n"
                x += "\t\t\t\t\t\t\t<RealtimeCmd Type=\"Key\" Source=\"Original\" UserProfile=\"0\" Environment=\"0\" User=\"1\" Status=\"On\" IsRealtime=\"1\" IsXFade=\"0\" IgnoreFollow=\"0\" IgnoreCommand=\"0\" Assert=\"0\" IgnoreNetwork=\"0\" FromTriggerNode=\"0\" IgnoreExecTime=\"0\" IssuedByTimecode=\"0\" FromLocalHardwareFader=\"1\" IgnoreExecXFade=\"0\" IsExecXFade=\"0\" Object=\"13.13.0.5.\(idx)\" ExecToken=\"Goto\" ValCueDestination=\"0.5.\(idx).\(c.cueThousandths)\" />\n"
                x += "\t\t\t\t\t\t</CmdEvent>\n"
            }
            x += "\t\t\t\t\t</CmdSubTrack>\n\t\t\t\t</TimeRange>\n\t\t\t</Track>\n"
        }
        x += """
        \t\t</TrackGroup>
        \t</Timecode>
        </GMA3>

        """
        return x
    }

    static func grandMA3FileName(trackName: String) -> String { "\(safe(trackName)).xml" }

    /// Number, Name, Timecode, Track time, Seconds, Colour — opens in Numbers/Excel, and imports
    /// into most marker tools (CuePoints, Reaper region CSV via a column map).
    static func csv(trackName: String, rows: [CuePointRow], clock: CuePointClock) -> String {
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var out = ["Number,Name,Timecode,Track time,Seconds,Colour"]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            out.append([String(r.number), q(r.name), clock.timecode(at: r.time).description,
                        clock.trackTime(r.time).description, String(format: "%.3f", r.time), r.colorHex ?? ""].joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    static func csvFileName(trackName: String) -> String { "\(safe(trackName)) cue points.csv" }

    /// Writes `text` to a temp file named `name` and returns its URL (for ShareLink / Files).
    static func write(_ text: String, name: String) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "cuepoints-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let r = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? "Track" : r
    }

    /// MA3-style GUID: 16 bytes as spaced upper-case hex.
    static func guid() -> String {
        let u = UUID().uuid
        return withUnsafeBytes(of: u) { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }
}
