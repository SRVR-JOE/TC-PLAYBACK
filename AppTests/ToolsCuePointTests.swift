import XCTest
import TCKit
@testable import TCPlayback

final class ToolsCuePointTests: XCTestCase {
    private let clock = CuePointClock(start: Timecode(hours: 16, rate: .fps30))
    private let rows = [CuePointRow(number: 1, name: "Verse 1", time: 30, colorHex: nil),
                        CuePointRow(number: 2, name: "Drop\t\"big\"", time: 5.0 + 2.0 / 30, colorHex: "#E5484D")]

    func testDisguiseMatchesDesignerLayout() {
        let s = CuePointExport.disguiseCueTable(trackName: "coffee", rows: rows, clock: clock)
        let lines = s.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Cue table for coffee")
        XCTAssertEqual(lines[1], "Beat\tTag\tNote\tTrack_Time\tTC_Time\tSection_Break")
        // Same shape as a Designer export: "0.00000\tTC 16:00:00:00\t\t00:00:00.00\t16:00:00.00\t1"
        XCTAssertEqual(lines[2], "0.00000\tTC 16:00:00:00\t\t00:00:00.00\t16:00:00.00\t1")
        // Sorted by time; tabs in names are flattened so columns never shift.
        XCTAssertEqual(lines[3], "5.06667\tCUE 2\tDrop \"big\"\t00:00:05.02\t16:00:05.02\t1")
        XCTAssertEqual(lines[4], "30.00000\tCUE 1\tVerse 1\t00:00:30.00\t16:00:30.00\t1")
        XCTAssertFalse(s.hasSuffix("\r\n"), "Designer files end without a trailing newline")
        for l in lines.dropFirst() { XCTAssertEqual(l.components(separatedBy: "\t").count, 6, l) }
    }

    func testDisguiseOptionsAndBPM() {
        var o = CuePointExport.DisguiseOptions()
        o.bpm = 120; o.tcTagAtStart = false; o.cueTags = false; o.sectionBreaks = false
        let lines = CuePointExport.disguiseCueTable(trackName: "t", rows: [rows[0]], clock: clock, options: o).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[2], "60.00000\t\tVerse 1\t00:00:30.00\t16:00:30.00\t0")
        XCTAssertEqual(CuePointExport.disguiseFileName(trackName: "Hind's Hall"), "Hind's Hall_cue_table.txt")
        XCTAssertEqual(CuePointExport.disguiseFileName(trackName: "LR/TC"), "LR-TC_cue_table.txt")
    }

    func testGrandMA3IsWellFormedWithMarkers() throws {
        let x = CuePointExport.grandMA3Timecode(trackName: "A & B <live>", rows: rows, clock: clock, duration: 200)
        final class P: NSObject, XMLParserDelegate {
            var markers: [[String: String]] = []; var timecode: [String: String] = [:]
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if e == "Marker" { markers.append(a) }
                if e == "Timecode" { timecode = a }
            }
        }
        let p = P(); let parser = XMLParser(data: Data(x.utf8)); parser.delegate = p
        XCTAssertTrue(parser.parse(), "\(parser.parserError?.localizedDescription ?? "")")
        XCTAssertEqual(p.timecode["Name"], "A & B <live>")
        XCTAssertEqual(p.timecode["Duration"], "200.00")
        XCTAssertEqual(p.markers.map { $0["Time"] }, ["5.07", "30.00"])
        XCTAssertEqual(p.markers.first?["Name"], "2 Drop \"big\"")
        XCTAssertEqual(p.markers.first?["Guid"]?.split(separator: " ").count, 16)
    }

    func testCSV() {
        let lines = CuePointExport.csv(trackName: "t", rows: rows, clock: clock).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Number,Name,Timecode,Track time,Seconds,Colour")
        XCTAssertEqual(lines[1], "2,\"Drop\t\"\"big\"\"\",16:00:05:02,00:00:05:02,5.067,#E5484D")
        XCTAssertEqual(lines[2], "1,\"Verse 1\",16:00:30:00,00:00:30:00,30.000,")
    }
}
