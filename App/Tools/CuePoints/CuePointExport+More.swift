import Foundation
import TCKit

// More cue-point exports, and the one list the export menu reads (`CuePointFormat`).
//
// Sources for the grandMA3 structures (MA does not publish the XML schema):
//  - console-validated timecode generator (2.4.2.2): github.com/herve8940/reacue reacue_mcp/lighting.py
//  - real console exports: github.com/bozi6/hello-world ma3_xmls_factory/orig/vivaldi_timecode.xml,
//    github.com/edendolev1/Reaper_Markers_GrandMA3 Example_timecode.xml, PhotonBoard macro-vivaldi.xml
//  - object model + RawTime = s x 2^24 probed on onPC 2.5.1: github.com/bdstark/gma3-mcp docs/probes/sb-08
//  - CueFade keyword: help.malighting.com/grandMA3/2.5/HTML/keyword_cuefade.html
//  - "Import Macro Library ... At Macro N": cuepoints-docs.super.site/grandma3

/// One file an export produces (most produce one; disguise-per-type produces one per cue type).
struct CuePointFile: Equatable {
    var name: String
    var text: String
}

/// Every export the cue-points tool offers, in menu order.
enum CuePointFormat: String, CaseIterable, Identifiable {
    case disguise, disguisePerType, grandMA3Timecode, grandMA3CueListMacro, csv, reaper, audition,
         eosASCII, eosCSV, chamsys, qlab

    /// How sure we are the target app reads the file as intended.
    enum Confidence: String {
        /// Checked byte-for-byte against files the target app wrote.
        case verified
        /// Structure copied from real/console-validated files; not yet run on our own rig.
        case sampleMatched
        /// Built from documentation/convention only; check on the target before the show.
        case bestGuess
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disguise: "disguise cue table"
        case .disguisePerType: "disguise cue tables, one per cue type"
        case .grandMA3Timecode: "grandMA3 timecode"
        case .grandMA3CueListMacro: "grandMA3 cue list macro"
        case .csv: "CSV spreadsheet"
        case .reaper: "Reaper markers CSV"
        case .audition: "Adobe Audition markers"
        case .eosASCII: "ETC Eos ASCII cue list"
        case .eosCSV: "ETC Eos CSV cue list"
        case .chamsys: "ChamSys MagicQ cue list CSV"
        case .qlab: "QLab cue list CSV"
        }
    }

    var fileExtension: String {
        switch self {
        case .disguise, .disguisePerType: "txt"
        case .grandMA3Timecode, .grandMA3CueListMacro: "xml"
        case .eosASCII: "asc"
        case .csv, .reaper, .audition, .eosCSV, .chamsys, .qlab: "csv"
        }
    }

    var confidence: Confidence {
        switch self {
        case .disguise, .disguisePerType, .csv: .verified
        case .grandMA3Timecode, .grandMA3CueListMacro, .reaper, .audition: .sampleMatched
        case .eosASCII, .eosCSV, .chamsys, .qlab: .bestGuess
        }
    }

    /// One line on where the file goes.
    var note: String {
        switch self {
        case .disguise: "Put in <project>/objects/table, named after the d3 track."
        case .disguisePerType: "One table per cue type; name each d3 track \"<track> <type>\"."
        case .grandMA3Timecode: "gma3_library/datapools/timecodes, then Import Timecode. Run the cue list macro first so the sequences and cue names exist."
        case .grandMA3CueListMacro: "gma3_library/datapools/macros, then Import Macro Library \"<file>\" At Macro <n> and run it. Builds one sequence per cue type."
        case .csv: "Opens in Numbers or Excel."
        case .reaper: "Reaper: View > Region/Marker Manager, right-click > Import."
        case .audition: "Audition: Markers panel > Import Markers."
        case .eosASCII: "Eos: File > Import > USITT ASCII. One cue list per cue type."
        case .eosCSV: "Eos: File > Import > CSV. Check against an export from your Eos version."
        case .chamsys: "MagicQ cue stack list with timecode column. Check against your MagicQ version."
        case .qlab: "QLab has no CSV import; for scripts or pasting into cue names and notes."
        }
    }

    func files(rows: [CuePointRow], clock: CuePointClock, trackName: String, types: [CuePointType] = [],
               duration: TimeInterval? = nil, disguise: CuePointExport.DisguiseOptions = .init()) -> [CuePointFile] {
        let E = CuePointExport.self
        let safe = E.safe(trackName)
        let dur = duration ?? ((rows.map(\.time).max() ?? 0) + 10)
        switch self {
        case .disguise:
            return [.init(name: E.disguiseFileName(trackName: trackName),
                          text: E.disguiseCueTable(trackName: trackName, rows: rows, clock: clock, options: disguise))]
        case .disguisePerType:
            return E.disguiseCueTablesPerType(trackName: trackName, rows: rows, clock: clock, types: types, options: disguise)
        case .grandMA3Timecode:
            return [.init(name: E.grandMA3FileName(trackName: trackName),
                          text: E.grandMA3Timecode(trackName: trackName, rows: rows, clock: clock, duration: dur, types: types))]
        case .grandMA3CueListMacro:
            return [.init(name: "\(safe) cue list macro.xml", text: E.grandMA3CueListMacro(trackName: trackName, rows: rows, types: types))]
        case .csv:
            return [.init(name: E.csvFileName(trackName: trackName), text: E.csv(trackName: trackName, rows: rows, clock: clock))]
        case .reaper:
            return [.init(name: "\(safe) Reaper markers.csv", text: E.reaperMarkers(rows: rows))]
        case .audition:
            return [.init(name: "\(safe) Audition markers.csv", text: E.auditionMarkers(rows: rows))]
        case .eosASCII:
            return [.init(name: "\(safe) Eos.asc", text: E.eosASCII(trackName: trackName, rows: rows, clock: clock, types: types))]
        case .eosCSV:
            return [.init(name: "\(safe) Eos cues.csv", text: E.eosCSV(rows: rows, clock: clock, types: types))]
        case .chamsys:
            return [.init(name: "\(safe) MagicQ cues.csv", text: E.chamsysCSV(rows: rows, clock: clock))]
        case .qlab:
            return [.init(name: "\(safe) QLab cues.csv", text: E.qlabCSV(rows: rows, clock: clock))]
        }
    }

    /// The text of a single-file export. For `.disguisePerType` this is the first table only; use `files`.
    func make(rows: [CuePointRow], clock: CuePointClock, trackName: String, types: [CuePointType] = []) -> String {
        files(rows: rows, clock: clock, trackName: trackName, types: types).first?.text ?? ""
    }

    /// Writes every file of the export to the temp export folder (for ShareLink / Files).
    func write(rows: [CuePointRow], clock: CuePointClock, trackName: String, types: [CuePointType] = [],
               duration: TimeInterval? = nil, disguise: CuePointExport.DisguiseOptions = .init()) throws -> [URL] {
        try files(rows: rows, clock: clock, trackName: trackName, types: types, duration: duration, disguise: disguise)
            .map { try CuePointExport.write($0.text, name: $0.name) }
    }
}

// MARK: - Grouping by cue type (shared by MA3, Eos, disguise-per-type)

extension CuePointExport {
    struct TypeGroup {
        struct Cue { var row: CuePointRow; var cue: String; var label: String
            /// MA internal cue number (cue 2.5 = 2500).
            var cueThousandths: Int { Int(((Double(cue) ?? 0) * 1000).rounded()) }
        }
        var typeName: String
        /// Console list number: the type's MA3 sequence, else its position + 1.
        var sequence: Int
        /// Name safe for an MA object path (no dots or double quotes).
        var sequenceName: String
        var cues: [Cue]
    }

    /// DataVersion written in MA3 files. Older versions import into newer consoles (2.3.0.0 into 2.5.1
    /// is reported); a newer one may be refused by an older console.
    static let ma3DataVersion = "2.3.0.0"

    /// MA's internal time unit: seconds x 2^24 (1.5 s = 25165824). XML exports write seconds in `Time`.
    static func ma3RawTime(_ seconds: TimeInterval) -> Int64 { Int64((max(0, seconds) * 16_777_216).rounded()) }

    static func ma3Escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A console object name: one line, no double quotes (they end a quoted name on the command line).
    static func consoleName(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A console cue number: the point's cue ID if it is a positive number (max 3 decimals), else its position.
    static func numericCue(_ r: CuePointRow) -> String {
        if let d = Double(r.consoleCueID.trimmingCharacters(in: .whitespaces)), d > 0, d.isFinite { return num(d) }
        return String(r.number)
    }

    /// "2", "1.5", "0.125" — no trailing zeros.
    static func num(_ d: Double) -> String {
        var s = String(format: "%.3f", d)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func typeGroups(rows: [CuePointRow], types: [CuePointType]) -> [TypeGroup] {
        func matchIndex(_ r: CuePointRow) -> Int? {
            if let id = r.typeID, let i = types.firstIndex(where: { $0.id == id }) { return i }
            return types.firstIndex { $0.name.caseInsensitiveCompare(r.typeName) == .orderedSame }
        }
        var known: [Int: [CuePointRow]] = [:]
        var unknownOrder: [String] = []; var unknown: [String: [CuePointRow]] = [:]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            if let i = matchIndex(r) { known[i, default: []].append(r) }
            else {
                let k = r.typeName.isEmpty ? "Cue" : r.typeName
                if unknown[k] == nil { unknownOrder.append(k) }
                unknown[k, default: []].append(r)
            }
        }
        var used = Set<Int>()
        var out: [TypeGroup] = []
        func make(_ name: String, _ seq: Int, _ rs: [CuePointRow]) -> TypeGroup {
            var s = max(1, seq); while used.contains(s) { s += 1 }; used.insert(s)
            var seen = Set<String>()
            let cues = rs.map { r -> TypeGroup.Cue in
                let cue = numericCue(r)
                var label = consoleName(r.name)
                if label.isEmpty { label = "Cue \(cue)" }
                if seen.contains(label) { label += " (\(cue))" }
                seen.insert(label)
                return .init(row: r, cue: cue, label: label)
            }
            let seqName = consoleName(name).replacingOccurrences(of: ".", with: "-")
            return TypeGroup(typeName: name, sequence: s, sequenceName: seqName.isEmpty ? "Sequence \(s)" : seqName, cues: cues)
        }
        for i in types.indices { if let rs = known[i] { out.append(make(types[i].name, types[i].ma3Sequence > 0 ? types[i].ma3Sequence : i + 1, rs)) } }
        for (k, name) in unknownOrder.enumerated() { out.append(make(name, types.count + k + 1, unknown[name]!)) }
        return out
    }

    static func ma3Groups(rows: [CuePointRow], types: [CuePointType]) -> [TypeGroup] { typeGroups(rows: rows, types: types) }

    // MARK: grandMA3 cue list macro

    /// grandMA3 macro library: one macro whose lines build the cue stacks — per cue type,
    /// `Store Sequence Y Cue X /Merge`, `Label Sequence Y Cue X "name"`, `Sequence Y Cue X CueFade in/out`,
    /// then `Label Sequence Y "<type>"` so the timecode export's Targets resolve by name.
    /// Starts with ClearAll so the stored cues are empty shells (nothing from the programmer).
    static func grandMA3CueListMacro(trackName: String, rows: [CuePointRow], types: [CuePointType] = []) -> String {
        var lines: [String] = ["ClearAll"]
        for g in typeGroups(rows: rows, types: types) {
            let y = g.sequence
            for c in g.cues {
                lines.append("Store Sequence \(y) Cue \(c.cue) /Merge")
                lines.append("Label Sequence \(y) Cue \(c.cue) \"\(c.label)\"")
                let fi = c.row.fadeIn, fo = c.row.fadeOut
                if fi != nil || fo != nil {
                    let f: String
                    if let a = fi, let b = fo { f = a == b ? num(a) : "\(num(a))/\(num(b))" }
                    else if let a = fi { f = "\(num(a))/" } else { f = "/\(num(fo!))" }
                    lines.append("Sequence \(y) Cue \(c.cue) CueFade \(f)")
                }
            }
            lines.append("Label Sequence \(y) \"\(g.sequenceName)\"")
        }
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<GMA3 DataVersion=\"\(ma3DataVersion)\">\n"
        x += "\t<Macro Name=\"\(ma3Escape(consoleName("CuePoints \(trackName)")))\" Guid=\"\(guid())\">\n"
        for l in lines { x += "\t\t<MacroLine Command=\"\(ma3Escape(l))\" Wait=\"0.10\" />\n" }
        x += "\t</Macro>\n</GMA3>\n"
        return x
    }

    // MARK: disguise, one table per type

    /// Same table as `disguiseCueTable`, split by cue type. Track name in each file is "<track> <type>".
    static func disguiseCueTablesPerType(trackName: String, rows: [CuePointRow], clock: CuePointClock,
                                         types: [CuePointType], options: DisguiseOptions = .init()) -> [CuePointFile] {
        typeGroups(rows: rows, types: types).map { g in
            let name = "\(trackName) \(g.typeName)"
            return CuePointFile(name: disguiseFileName(trackName: name),
                                text: disguiseCueTable(trackName: name, rows: g.cues.map(\.row), clock: clock, options: options))
        }
    }

    // MARK: DAWs

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }

    /// "H:MM:SS.mmm" (Reaper's H:M:S style; Reaper also reads it whatever the ruler is set to).
    static func hmsms(_ t: TimeInterval) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Reaper Region/Marker Manager CSV: `#,Name,Start,End,Length,Color`, markers as `M<n>` with
    /// empty End/Length, colour as RRGGBB hex.
    static func reaperMarkers(rows: [CuePointRow]) -> String {
        var out = ["#,Name,Start,End,Length,Color"]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            let color = (r.colorHex ?? "").replacingOccurrences(of: "#", with: "").uppercased()
            out.append(["M\(r.number)", csvField(r.name), hmsms(r.time), "", "", color].joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Audition marker list: tab-separated `Name Start Duration Time Format Type Description`, decimal
    /// time `M:SS.sss` (H:MM:SS.sss past an hour), point markers of type Cue.
    static func auditionMarkers(rows: [CuePointRow]) -> String {
        func dec(_ t: TimeInterval) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
            return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, f) : String(format: "%d:%02d.%03d", m, s, f)
        }
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").components(separatedBy: .newlines).joined(separator: " ") }
        var out = ["Name\tStart\tDuration\tTime Format\tType\tDescription"]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            out.append([clean(r.name), dec(r.time), "0:00.000", "decimal", "Cue", r.typeName == "Cue" ? "" : clean(r.typeName)].joined(separator: "\t"))
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Lighting consoles

    /// USITT ASCII Light Cues file for Eos: `Cue <n> <list>`, `Text`, `Up`/`Down` fade times,
    /// one cue list per cue type, timecode as a comment. Ends with `EndData`.
    static func eosASCII(trackName: String, rows: [CuePointRow], clock: CuePointClock, types: [CuePointType] = []) -> String {
        var out = ["! \(consoleName(trackName)) — cue points from TC Playback",
                   "! Start timecode \(clock.start.description) @ \(clock.rate.label)",
                   "Ident 3:0", "Manufacturer ETC", "Console Eos", ""]
        for g in typeGroups(rows: rows, types: types) {
            out.append("! Cue list \(g.sequence): \(g.sequenceName)")
            for c in g.cues {
                out.append("Cue \(c.cue) \(g.sequence)")
                out.append("Text \(c.label)")
                if let a = c.row.fadeIn { out.append("Up \(num(a))") }
                if let b = c.row.fadeOut { out.append("Down \(num(b))") }
                out.append("! TC \(clock.timecode(at: c.row.time).description)")
                out.append("")
            }
        }
        out.append("EndData")
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// Eos spreadsheet CSV (the START_TARGETS block Eos writes on CSV export), cue rows only.
    static func eosCSV(rows: [CuePointRow], clock: CuePointClock, types: [CuePointType] = []) -> String {
        var out = ["START_TARGETS",
                   "1,TARGET_TYPE,TARGET_TYPE_AS_TEXT,TARGET_LIST_NUMBER,TARGET_ID,TARGET_DCID,PART_NUMBER,LABEL,TIME_DATA,UP_DELAY,DOWN_TIME,DOWN_DELAY,CUE_NOTES"]
        var n = 1
        for g in typeGroups(rows: rows, types: types) {
            for c in g.cues {
                n += 1
                out.append([String(n), "1", "Cue", String(g.sequence), c.cue, "", "", csvField(c.label),
                            c.row.fadeIn.map(num) ?? "", "", c.row.fadeOut.map(num) ?? "", "",
                            csvField("TC \(clock.timecode(at: c.row.time).description)")].joined(separator: ","))
            }
        }
        out.append("END_TARGETS")
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// ChamSys MagicQ cue list: cue number, name, fade in/out, timecode.
    static func chamsysCSV(rows: [CuePointRow], clock: CuePointClock) -> String {
        var out = ["Cue,Name,Fade In,Fade Out,Timecode,Type"]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            out.append([numericCue(r), csvField(r.name), r.fadeIn.map(num) ?? "", r.fadeOut.map(num) ?? "",
                        clock.timecode(at: r.time).description, csvField(r.typeName)].joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// QLab-style list: Number, Name, Type, Timecode, Seconds, Fade, Notes.
    static func qlabCSV(rows: [CuePointRow], clock: CuePointClock) -> String {
        var out = ["Number,Name,Type,Timecode,Seconds,Fade,Notes"]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            out.append([csvField(r.consoleCueID), csvField(r.name), csvField(r.typeName), clock.timecode(at: r.time).description,
                        String(format: "%.3f", r.time), r.fadeIn.map(num) ?? "", ""].joined(separator: ","))
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }
}
