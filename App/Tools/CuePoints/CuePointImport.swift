import Foundation
import TCKit

/// A marker read from another app's file. `time` is seconds from the start of the track.
struct ImportedPoint: Equatable {
    var time: TimeInterval
    var name: String
    var cueID: String = ""
    var typeName: String? = nil
    var colorHex: String? = nil
}

/// Reads markers from: CSV/TSV (header sniffed), disguise cue tables, Reaper marker CSV, Audition
/// marker lists, grandMA3 timecode XML (markers and command events), and BWF/WAV `cue ` + `LIST/adtl`
/// chunks. `parse` picks the reader from the file's content (the filename is a hint only).
enum CuePointImport {
    enum Source: String { case csv, disguise, grandMA3, wav }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case noMarkers(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't text, a grandMA3 XML or a WAV file."
            case .noMarkers(let what): "No markers found in this \(what)."
            }
        }
    }

    /// File extensions the importer understands (for the file picker).
    static let fileExtensions = ["csv", "tsv", "txt", "xml", "wav", "wave", "bwf"]

    static func detect(data: Data, filename: String = "") -> Source? {
        if data.count >= 12, let id = String(data: data[data.startIndex..<data.startIndex + 4], encoding: .ascii),
           ["RIFF", "RF64", "BW64"].contains(id) { return .wav }
        guard let text = decode(data) else { return nil }
        let head = text.prefix(4096)
        if head.contains("<GMA3") { return .grandMA3 }
        if head.hasPrefix("Cue table for") || head.contains("Beat\tTag\tNote\tTrack_Time") { return .disguise }
        return .csv
    }

    /// - Parameter clock: the track's clock. Needed to read frame timecode (HH:MM:SS:FF) — absolute
    ///   timecode columns are converted to track time by subtracting `clock.start`. Without it, frame
    ///   timecode is read at 30 fps from 00:00:00:00.
    static func parse(data: Data, filename: String = "", clock: CuePointClock? = nil) throws -> [ImportedPoint] {
        guard let src = detect(data: data, filename: filename) else { throw Failure.unreadable }
        let points: [ImportedPoint]
        switch src {
        case .wav: points = try parseWAV(data)
        case .grandMA3: points = try parseGrandMA3(data)
        case .disguise: points = parseDisguise(decode(data) ?? "", clock: clock)
        case .csv: points = parseTable(decode(data) ?? "", clock: clock)
        }
        if points.isEmpty { throw Failure.noMarkers(src == .wav ? "audio file" : "file") }
        return points.sorted { $0.time < $1.time }
    }

    // MARK: - Text

    static func decode(_ data: Data) -> String? {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) }
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .isoLatin1)
    }

    /// RFC 4180-ish: quoted fields with "" escapes and embedded separators/newlines.
    static func rows(_ text: String, separator: Character) -> [[String]] {
        var out: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false
        var it = Array(text); var i = 0
        if it.first == "\u{FEFF}" { it.removeFirst() }
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" { if i + 1 < it.count, it[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { out.append(row) }
                row = []
                if c == "\r", i + 1 < it.count, it[i + 1] == "\n" { i += 1 }
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); out.append(row) }
        return out
    }

    // MARK: - Time

    /// Seconds from a time cell: plain seconds, `H:MM:SS.mmm` / `M:SS.mmm`, or frame timecode
    /// `HH:MM:SS:FF` (`;` for drop-frame) at the clock's rate. `absolute` = the column holds timecode
    /// on the show's timeline (subtract the clock start).
    static func seconds(_ raw: String, clock: CuePointClock?, absolute: Bool) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if let v = Double(s), v.isFinite { return max(0, v) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let isFrameTC = parts.count == 4 || (parts.count == 3 && s.contains(";"))
        if isFrameTC {
            let rate = clock?.rate ?? .fps30
            guard let tc = Timecode(string: s, rate: rate) else { return nil }
            return fromTimecode(tc, clock: clock, absolute: absolute)
        }
        guard (2...3).contains(parts.count) else { return nil }
        let nums = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.allSatisfy({ $0 != nil }) else { return nil }
        let v = nums.reduce(0.0) { $0 * 60 + $1! }
        if absolute, let c = clock, parts.count == 3, v >= c.start.realSeconds - 0.0005 { return v - c.start.realSeconds }
        return v
    }

    static func fromTimecode(_ tc: Timecode, clock: CuePointClock?, absolute: Bool) -> TimeInterval {
        guard absolute, let c = clock else { return tc.realSeconds }
        let perDay = Timecode(hours: 23, minutes: 59, seconds: 59, frames: c.rate.nominalFPS - 1, rate: c.rate).frameNumber + 1
        let d = ((tc.frameNumber - c.start.frameNumber) % perDay + perDay) % perDay
        return Double(d) / c.rate.fps
    }

    // MARK: - CSV / TSV

    enum Column { case seconds, time, timecode, name, cue, colour, type }

    static func column(for header: String) -> Column? {
        let h = header.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "#" }
        switch h {
        case "seconds", "secs", "sec", "times", "timeseconds", "timesec", "positionseconds", "startseconds": return .seconds
        case "timecode", "tc", "tctime", "smpte", "ltc", "timecodein": return .timecode
        case "tracktime", "time", "start", "position", "pos", "in", "starttime", "markerstart", "location": return .time
        case "name", "label", "text", "note", "marker", "markername", "cuename", "title", "qname", "description", "comment": return .name
        case "cue", "cueid", "cuenumber", "cueno", "number", "no", "#", "id", "q", "qnumber", "index": return .cue
        case "colour", "color", "colorhex", "colourhex": return .colour
        case "type", "cuetype", "lane", "layer", "track", "kind", "category": return .type
        default: return nil
        }
    }

    /// Name-ish columns in preference order (a file with Name and Description keeps Name).
    private static let namePriority = ["name", "label", "cuename", "qname", "markername", "text", "note", "marker", "title", "description", "comment"]

    static func parseTable(_ text: String, clock: CuePointClock?) -> [ImportedPoint] {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sep: Character = firstLine.contains("\t") ? "\t"
            : (firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ",")
        let table = rows(text, separator: sep)
        guard let header = table.first else { return [] }
        var idx: [Column: Int] = [:]
        for (i, h) in header.enumerated() {
            guard let c = column(for: h) else { continue }
            if c == .name {
                let key = h.lowercased().filter { $0.isLetter || $0.isNumber }
                if let cur = idx[.name] {
                    let curKey = header[cur].lowercased().filter { $0.isLetter || $0.isNumber }
                    if (namePriority.firstIndex(of: key) ?? 99) < (namePriority.firstIndex(of: curKey) ?? 99) { idx[.name] = i }
                } else { idx[.name] = i }
            } else if idx[c] == nil { idx[c] = i }
        }
        let hasHeader = !idx.isEmpty
        if !hasHeader {
            // Headerless: first time-looking column, first other text column as the name.
            guard let probe = table.first else { return [] }
            if let t = probe.firstIndex(where: { seconds($0, clock: clock, absolute: false) != nil }) {
                idx[.time] = t
                if let n = probe.indices.first(where: { $0 != t && !probe[$0].isEmpty }) { idx[.name] = n }
            }
        }
        guard idx[.seconds] != nil || idx[.time] != nil || idx[.timecode] != nil else { return [] }
        var out: [ImportedPoint] = []
        for r in table.dropFirst(hasHeader ? 1 : 0) {
            func cell(_ c: Column) -> String? { idx[c].flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil } }
            let t = cell(.seconds).flatMap { seconds($0, clock: clock, absolute: false) }
                ?? cell(.time).flatMap { seconds($0, clock: clock, absolute: false) }
                ?? cell(.timecode).flatMap { seconds($0, clock: clock, absolute: true) }
            guard let time = t else { continue }
            var cue = cell(.cue) ?? ""
            // Reaper marks rows "M3" / regions "R3".
            if let f = cue.first, (f == "M" || f == "R"), Int(cue.dropFirst()) != nil { cue = String(cue.dropFirst()) }
            out.append(ImportedPoint(time: time, name: cell(.name) ?? "", cueID: cue,
                                     typeName: cell(.type).flatMap { $0.isEmpty ? nil : $0 },
                                     colorHex: cell(.colour).flatMap(normaliseColour)))
        }
        return out
    }

    /// "#E5484D", "E5484D", "e5484d" -> "#E5484D"; anything else -> nil.
    static func normaliseColour(_ s: String) -> String? {
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").uppercased()
        guard h.count == 6, h.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + h
    }

    // MARK: - disguise cue table

    /// Our own (and Designer's) cue table. Uses Track_Time (frames at the clock's rate) when a clock
    /// is given, else Beat at 60 BPM. Skips the "TC hh:mm:ss:ff" start tag.
    static func parseDisguise(_ text: String, clock: CuePointClock?) -> [ImportedPoint] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let hi = lines.firstIndex(where: { $0.hasPrefix("Beat\t") }) else { return [] }
        let header = lines[hi].components(separatedBy: "\t")
        func col(_ n: String) -> Int? { header.firstIndex(of: n) }
        var out: [ImportedPoint] = []
        for l in lines[(hi + 1)...] {
            let f = l.components(separatedBy: "\t")
            func cell(_ n: String) -> String { col(n).map { $0 < f.count ? f[$0] : "" } ?? "" }
            let tag = cell("Tag"), note = cell("Note")
            if tag.hasPrefix("TC "), note.isEmpty { continue }
            var t: TimeInterval?
            if let c = clock, let tc = Timecode(string: cell("Track_Time"), rate: c.rate) { t = tc.realSeconds }
            if t == nil { t = Double(cell("Beat")) }
            guard let time = t else { continue }
            var cue = ""
            if tag.uppercased().hasPrefix("CUE ") { cue = String(tag.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            out.append(ImportedPoint(time: time, name: note, cueID: cue))
        }
        return out
    }

    // MARK: - grandMA3 timecode XML

    private final class MA3Reader: NSObject, XMLParserDelegate {
        var markers: [ImportedPoint] = []
        var events: [ImportedPoint] = []
        var track: String?
        var pending: ImportedPoint?

        static func time(_ a: [String: String]) -> TimeInterval? {
            if let raw = a["RawTime"], let v = Double(raw) { return v / 16_777_216 }
            return a["Time"].flatMap { CuePointImport.seconds($0, clock: nil, absolute: false) }
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "Track":
                var name = a["Name"]
                if name?.isEmpty ?? true, let target = a["Target"] { name = target.components(separatedBy: ".").last }
                track = name
            case "Marker":
                if let t = Self.time(a) { markers.append(ImportedPoint(time: t, name: a["Name"] ?? "")) }
            case "CmdEvent":
                if let t = Self.time(a) { pending = ImportedPoint(time: t, name: a["CueDestination"] ?? a["Name"] ?? "", typeName: track) }
            case "RealtimeCmd":
                if let v = a["ValCueDestination"], let last = v.components(separatedBy: ".").last, let n = Double(last), n > 0 {
                    pending?.cueID = CuePointExport.num(n / 1000)
                }
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "CmdEvent", let ev = pending { events.append(ev); pending = nil }
            if e == "Track" { track = nil }
        }
    }

    /// Command events (with their track as the type and the cue they go to), plus any markers that
    /// don't sit on an event (our own export writes both for every point).
    static func parseGrandMA3(_ data: Data) throws -> [ImportedPoint] {
        let r = MA3Reader(); let p = XMLParser(data: data); p.delegate = r
        guard p.parse() else { throw Failure.unreadable }
        let extra = r.markers.filter { m in !r.events.contains { abs($0.time - m.time) < 0.0105 } }
        return r.events + extra
    }

    // MARK: - BWF / WAV markers

    /// RIFF `cue ` points (sample offsets) named by `LIST/adtl/labl` (or `note`), seconds from the
    /// `fmt ` sample rate. Handles odd-size chunk padding and RF64/BW64 headers.
    static func parseWAV(_ data: Data) throws -> [ImportedPoint] {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        func id(_ o: Int) -> String { o + 4 <= b.count ? String(bytes: b[o..<o + 4], encoding: .ascii) ?? "" : "" }
        func cstr(_ o: Int, _ end: Int) -> String {
            guard o < end else { return "" }
            var e = o; while e < end, b[e] != 0 { e += 1 }
            let bytes = Array(b[o..<e])
            return (String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard b.count >= 12, ["RIFF", "RF64", "BW64"].contains(id(0)), id(8) == "WAVE" else { throw Failure.unreadable }
        var rate = 0
        var cues: [(id: Int, position: Int, offset: Int)] = []
        var labels: [Int: String] = [:], notes: [Int: String] = [:]
        var o = 12
        while o + 8 <= b.count {
            let cid = id(o); var size = u32(o + 4); let body = o + 8
            if size == 0xFFFF_FFFF { size = max(0, b.count - body) } // RF64 data chunk: size lives in ds64
            let end = min(b.count, body + size)
            switch cid {
            case "fmt ": rate = u32(body + 4)
            case "cue ":
                let n = u32(body)
                for i in 0..<n {
                    let e = body + 4 + i * 24
                    guard e + 24 <= end else { break }
                    cues.append((u32(e), u32(e + 4), u32(e + 20)))
                }
            case "LIST" where id(body) == "adtl":
                var s = body + 4
                while s + 8 <= end {
                    let sid = id(s), ssize = u32(s + 4), sb = s + 8, se = min(end, sb + ssize)
                    if sid == "labl" { labels[u32(sb)] = cstr(sb + 4, se) }
                    if sid == "note" { notes[u32(sb)] = cstr(sb + 4, se) }
                    s = sb + ssize + (ssize & 1)
                }
            default: break
            }
            o = body + size + (size & 1)
        }
        guard rate > 0 else { throw Failure.unreadable }
        return cues.map { c in
            let sample = c.offset != 0 ? c.offset : c.position
            let name = labels[c.id] ?? notes[c.id] ?? "Marker \(c.id)"
            return ImportedPoint(time: Double(sample) / Double(rate), name: name)
        }
    }
}
