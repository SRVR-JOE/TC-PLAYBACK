import XCTest
import TCKit
@testable import TCPlayback

final class ToolsCuePointFormatsTests: XCTestCase {
    private let clock = CuePointClock(start: Timecode(hours: 16, rate: .fps30))
    private let lightsID = UUID()
    private var types: [CuePointType] {
        [CuePointType(id: CuePointType.defaultID, name: "Cue", colorHex: "#E5A50A", ma3Sequence: 0),
         CuePointType(id: lightsID, name: "Lights", colorHex: "#3D8BFD", ma3Sequence: 7)]
    }
    private var rows: [CuePointRow] {
        [CuePointRow(number: 1, name: "Intro", time: 1.5, colorHex: "#E5484D", cueID: "1", typeName: "Cue",
                     typeID: CuePointType.defaultID, fadeIn: 2, fadeOut: 2),
         CuePointRow(number: 2, name: "Drop, \"big\"", time: 5.0 + 2.0 / 30, colorHex: nil, cueID: "2.5", typeName: "Lights",
                     typeID: lightsID, fadeIn: 1, fadeOut: 3),
         CuePointRow(number: 3, name: "Outro", time: 30, colorHex: "#2FB85A", cueID: "", typeName: "Cue",
                     typeID: CuePointType.defaultID)]
    }

    private final class XMLCollector: NSObject, XMLParserDelegate {
        var elements: [(String, [String: String])] = []
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            elements.append((e, a))
        }
        func all(_ name: String) -> [[String: String]] { elements.filter { $0.0 == name }.map(\.1) }
    }
    private func parseXML(_ s: String) -> XMLCollector {
        let c = XMLCollector(); let p = XMLParser(data: Data(s.utf8)); p.delegate = c
        XCTAssertTrue(p.parse(), "\(p.parserError?.localizedDescription ?? "")")
        return c
    }

    // MARK: grandMA3

    func testMA3TimecodeFiresCuesPerType() {
        let x = CuePointExport.grandMA3Timecode(trackName: "Show & Tell", rows: rows, clock: clock, duration: 60, types: types)
        let c = parseXML(x)
        XCTAssertEqual(c.all("Marker").count, 3, "Marker track kept")
        let tracks = c.all("Track")
        XCTAssertEqual(tracks.map { $0["Target"] }, ["ShowData.DataPools.Default.Sequences.Cue", "ShowData.DataPools.Default.Sequences.Lights"])
        let events = c.all("CmdEvent")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?["Time"], "1.500")
        XCTAssertEqual(events.first?["CueDestination"], "Intro")
        XCTAssertEqual(CuePointExport.ma3RawTime(1.5), 25_165_824)
        let cmds = c.all("RealtimeCmd")
        XCTAssertTrue(cmds.allSatisfy { $0["ExecToken"] == "Goto" })
        // Cue type 0 -> sequence = index + 1 = 1 (pool index 0); Lights -> sequence 7 (pool index 6), cue 2.5 -> 2500.
        XCTAssertEqual(cmds.map { $0["ValCueDestination"] }, ["0.5.0.1000", "0.5.0.3000", "0.5.6.2500"])
        XCTAssertEqual(c.all("Timecode").first?["Name"], "Show & Tell")
    }

    func testMA3MacroBuildsCueStacks() {
        let x = CuePointExport.grandMA3CueListMacro(trackName: "t", rows: rows, types: types)
        let lines = parseXML(x).all("MacroLine").compactMap { $0["Command"] }
        XCTAssertEqual(lines.first, "ClearAll")
        XCTAssertTrue(lines.contains("Store Sequence 1 Cue 1 /Merge"))
        XCTAssertTrue(lines.contains("Label Sequence 1 Cue 1 \"Intro\""))
        XCTAssertTrue(lines.contains("Sequence 1 Cue 1 CueFade 2"))
        XCTAssertTrue(lines.contains("Store Sequence 7 Cue 2.5 /Merge"))
        XCTAssertTrue(lines.contains("Label Sequence 7 Cue 2.5 \"Drop, 'big'\""))
        XCTAssertTrue(lines.contains("Sequence 7 Cue 2.5 CueFade 1/3"))
        XCTAssertTrue(lines.contains("Store Sequence 1 Cue 3 /Merge"), "empty cue ID falls back to the point number")
        XCTAssertTrue(lines.contains("Label Sequence 7 \"Lights\""))
    }

    func testMA3RoundTrip() throws {
        let x = CuePointExport.grandMA3Timecode(trackName: "t", rows: rows, clock: clock, duration: 60, types: types)
        let pts = try CuePointImport.parse(data: Data(x.utf8), filename: "t.xml")
        XCTAssertEqual(pts.count, 3, "markers on events are not duplicated")
        // Console names can't hold double quotes, so the export swaps them for single ones.
        XCTAssertEqual(pts.map(\.name), ["Intro", "Drop, 'big'", "Outro"])
        XCTAssertEqual(pts.map(\.cueID), ["1", "2.5", "3"])
        XCTAssertEqual(pts.map(\.typeName), ["Cue", "Lights", "Cue"])
        for (p, r) in zip(pts, rows.sorted { $0.time < $1.time }) { XCTAssertEqual(p.time, r.time, accuracy: 0.001) }
    }

    func testMA3MarkerOnlyImport() throws {
        let x = """
        <?xml version="1.0" encoding="UTF-8"?><GMA3 DataVersion="2.0.0.0"><Timecode Name="a"><TrackGroup>
        <MarkerTrack Name="Marker"><Marker Name="Verse" Time="12.25" /></MarkerTrack>
        <Track Name="S"><TimeRange><CmdSubTrack><CmdEvent Name="Go+" RawTime="25165824"><RealtimeCmd ExecToken="Go+" /></CmdEvent></CmdSubTrack></TimeRange></Track>
        </TrackGroup></Timecode></GMA3>
        """
        let pts = try CuePointImport.parse(data: Data(x.utf8))
        XCTAssertEqual(pts.map(\.time), [1.5, 12.25])
        XCTAssertEqual(pts.map(\.name), ["Go+", "Verse"])
    }

    // MARK: disguise

    func testDisguiseFormatIsByteIdenticalAndRoundTrips() throws {
        let def = CuePointExport.disguiseCueTable(trackName: "coffee", rows: rows, clock: clock)
        XCTAssertEqual(CuePointFormat.disguise.make(rows: rows, clock: clock, trackName: "coffee"), def)
        let pts = try CuePointImport.parse(data: Data(def.utf8), filename: "coffee_cue_table.txt", clock: clock)
        XCTAssertEqual(pts.map(\.name), ["Intro", "Drop, \"big\"", "Outro"])
        XCTAssertEqual(pts.map(\.cueID), ["1", "2", "3"])
        for (p, r) in zip(pts, rows) { XCTAssertEqual(p.time, r.time, accuracy: 1.0 / 30) }
        // Without a clock, Beat (60 BPM) is used.
        let beat = try CuePointImport.parse(data: Data(def.utf8))
        XCTAssertEqual(beat[1].time, 5.0 + 2.0 / 30, accuracy: 0.0001)
    }

    func testDisguisePerType() {
        let files = CuePointFormat.disguisePerType.files(rows: rows, clock: clock, trackName: "song", types: types)
        XCTAssertEqual(files.map(\.name), ["song Cue_cue_table.txt", "song Lights_cue_table.txt"])
        XCTAssertTrue(files[1].text.hasPrefix("Cue table for song Lights\r\n"))
        XCTAssertEqual(files[0].text.components(separatedBy: "\r\n").count, 2 + 1 + 2)
    }

    // MARK: DAWs + CSV

    func testReaperShapeAndRoundTrip() throws {
        let s = CuePointExport.reaperMarkers(rows: rows)
        let lines = s.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "#,Name,Start,End,Length,Color")
        XCTAssertEqual(lines[1], "M1,Intro,0:00:01.500,,,E5484D")
        XCTAssertEqual(lines[2], "M2,\"Drop, \"\"big\"\"\",0:00:05.067,,,")
        let pts = try CuePointImport.parse(data: Data(s.utf8), filename: "m.csv")
        XCTAssertEqual(pts.map(\.name), ["Intro", "Drop, \"big\"", "Outro"])
        XCTAssertEqual(pts.map(\.cueID), ["1", "2", "3"])
        XCTAssertEqual(pts[0].colorHex, "#E5484D")
        XCTAssertEqual(pts[1].time, 5.067, accuracy: 0.0005)
    }

    func testCSVRoundTrip() throws {
        let s = CuePointExport.csv(trackName: "t", rows: rows, clock: clock)
        let pts = try CuePointImport.parse(data: Data(s.utf8), filename: "t.csv", clock: clock)
        XCTAssertEqual(pts.map(\.name), ["Intro", "Drop, \"big\"", "Outro"])
        for (p, r) in zip(pts, rows) { XCTAssertEqual(p.time, r.time, accuracy: 0.001) }
        XCTAssertEqual(pts[2].colorHex, "#2FB85A")
    }

    func testCSVHeaderSniffingTimecodeAndTSV() throws {
        // Absolute timecode on the show line -> track time via the clock start.
        let tc = "Cue;Label;TC\n10;Hit;16:00:02:15\n11;Out;16:01:00:00\n"
        let a = try CuePointImport.parse(data: Data(tc.utf8), clock: clock)
        XCTAssertEqual(a.map(\.time), [2.5, 60])
        XCTAssertEqual(a.map(\.cueID), ["10", "11"])
        let tsv = "Marker Name\tPosition\n\"A\tB\"\t1:02.250\nC\t01:00:00.5\n"
        let b = try CuePointImport.parse(data: Data(tsv.utf8))
        XCTAssertEqual(b.map(\.name), ["A\tB", "C"])
        XCTAssertEqual(b[0].time, 62.25, accuracy: 0.0001)
        XCTAssertEqual(b[1].time, 3600.5, accuracy: 0.0001)
    }

    func testAuditionShapeAndImport() throws {
        let s = CuePointExport.auditionMarkers(rows: rows)
        let lines = s.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Name\tStart\tDuration\tTime Format\tType\tDescription")
        XCTAssertEqual(lines[1], "Intro\t0:01.500\t0:00.000\tdecimal\tCue\t")
        let pts = try CuePointImport.parse(data: Data(s.utf8))
        XCTAssertEqual(pts.map(\.time), [1.5, 5.067, 30])
    }

    // MARK: Consoles

    func testEosASCIIShape() {
        let s = CuePointExport.eosASCII(trackName: "t", rows: rows, clock: clock, types: types)
        let lines = s.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("Ident 3:0"))
        XCTAssertTrue(lines.contains("Manufacturer ETC"))
        XCTAssertTrue(lines.contains("Console Eos"))
        let i = lines.firstIndex(of: "Cue 2.5 7")!
        XCTAssertEqual(Array(lines[i...(i + 3)]), ["Cue 2.5 7", "Text Drop, 'big'", "Up 1", "Down 3"])
        XCTAssertTrue(lines.contains("Cue 1 1"))
        XCTAssertEqual(lines.last(where: { !$0.isEmpty }), "EndData")
    }

    func testEosCSVAndChamSysShape() {
        let e = CuePointExport.eosCSV(rows: rows, clock: clock, types: types).components(separatedBy: "\r\n")
        XCTAssertEqual(e.first, "START_TARGETS")
        XCTAssertTrue(e.contains("END_TARGETS"))
        XCTAssertEqual(e.count, 2 + 3 + 2) // header block + 3 cues + END + trailing empty
        XCTAssertTrue(e[2].hasPrefix("2,1,Cue,1,1,,,Intro,2,,2,,"))
        let c = CuePointExport.chamsysCSV(rows: rows, clock: clock).components(separatedBy: "\r\n")
        XCTAssertEqual(c[0], "Cue,Name,Fade In,Fade Out,Timecode,Type")
        XCTAssertEqual(c[1], "1,Intro,2,2,16:00:01:15,Cue")
        XCTAssertEqual(c[2], "2.5,\"Drop, \"\"big\"\"\",1,3,16:00:05:02,Lights")
        XCTAssertEqual(c[3], "3,Outro,,,16:00:30:00,Cue")
    }

    func testEveryFormatProducesFiles() {
        for f in CuePointFormat.allCases {
            let files = f.files(rows: rows, clock: clock, trackName: "t", types: types)
            XCTAssertFalse(files.isEmpty, f.label)
            for file in files {
                XCTAssertTrue(file.name.hasSuffix("." + f.fileExtension), "\(f.label): \(file.name)")
                XCTAssertFalse(file.text.isEmpty, f.label)
            }
        }
    }

    // MARK: BWF

    private func wav(rate: UInt32, cues: [(UInt32, UInt32, String)]) -> Data {
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            Array(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
        }
        let fmt = chunk("fmt ", le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16))
        let pcm = chunk("data", [UInt8](repeating: 0, count: 64))
        var cueBody = le32(UInt32(cues.count))
        for (id, offset, _) in cues { cueBody += le32(id) + le32(offset) + Array("data".utf8) + le32(0) + le32(0) + le32(offset) }
        var adtl = Array("adtl".utf8)
        for (id, _, label) in cues { adtl += chunk("labl", le32(id) + Array(label.utf8) + [0]) }
        let body = Array("WAVE".utf8) + fmt + pcm + chunk("cue ", cueBody) + chunk("LIST", adtl)
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }

    func testBWFCueAndLabelChunks() throws {
        // labl "Verse": 4-byte id + "Verse\0" = 10 bytes; "Go": 4 + 3 = 7, so that chunk gets a pad byte.
        let d = wav(rate: 48_000, cues: [(1, 72_000, "Verse"), (2, 1_440_000, "Go")])
        let pts = try CuePointImport.parse(data: d, filename: "mix.wav")
        XCTAssertEqual(pts, [ImportedPoint(time: 1.5, name: "Verse"), ImportedPoint(time: 30, name: "Go")])
        XCTAssertThrowsError(try CuePointImport.parse(data: wav(rate: 48_000, cues: []), filename: "x.wav"))
    }
}
