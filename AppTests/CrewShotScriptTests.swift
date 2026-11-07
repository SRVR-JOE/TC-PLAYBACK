import XCTest
import SwiftData
import TCKit
@testable import TCPlayback

/// The CuePoint schema as it was before the crew shot fields (entity name "CuePoint").
enum CrewMigrationV1 {
    @Model
    final class CuePoint {
        @Attribute(.unique) var id: UUID
        var trackID: UUID
        var time: TimeInterval
        var name: String
        var colorHex: String?
        var createdAt: Date
        var typeID: UUID? = nil
        var cueID: String = ""
        var fade: String = ""
        init(trackID: UUID, time: TimeInterval, name: String) {
            id = UUID(); self.trackID = trackID; self.time = time; self.name = name; createdAt = .now
        }
    }
}

final class CrewShotScriptTests: XCTestCase {
    let lane = UUID(), lane2 = UUID()

    func shot(_ t: TimeInterval, cam: Int?, _ no: String = "", lane l: UUID? = nil, hold: Bool = true) -> CrewCue {
        CrewCue(id: UUID(), time: t, name: "S\(no)", laneID: l ?? lane, camera: cam, shotNumber: no, shotSize: "MS",
                shotNote: "", holdUntilNext: hold)
    }

    func testNewFieldsDefault() {
        let p = CuePoint(trackID: UUID(), time: 1, name: "x")
        XCTAssertNil(p.camera); XCTAssertEqual(p.shotNumber, ""); XCTAssertEqual(p.shotSize, "")
        XCTAssertEqual(p.shotNote, ""); XCTAssertTrue(p.holdUntilNext)
    }

    func testOldStoreOpensWithNewSchema() throws {
        let url = URL.temporaryDirectory.appending(path: "crew-migration-\(UUID().uuidString).store")
        defer { for s in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + s)) } }
        let track = UUID()
        do {
            let old = try ModelContainer(for: CrewMigrationV1.CuePoint.self, configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(old)
            let p = CrewMigrationV1.CuePoint(trackID: track, time: 12.5, name: "Drop")
            p.cueID = "7"
            ctx.insert(p)
            try ctx.save()
        }
        let new = try ModelContainer(for: TCPlayback.CuePoint.self, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(new)
        let pts = TCPlayback.CuePoint.points(for: track, in: ctx)
        XCTAssertEqual(pts.count, 1)
        let p = try XCTUnwrap(pts.first)
        XCTAssertEqual(p.name, "Drop"); XCTAssertEqual(p.cueID, "7"); XCTAssertEqual(p.time, 12.5)
        XCTAssertNil(p.camera); XCTAssertEqual(p.shotNumber, ""); XCTAssertTrue(p.holdUntilNext)
        p.camera = 3; p.shotSize = "CU"
        try ctx.save()
        XCTAssertEqual(TCPlayback.CuePoint.points(for: track, in: ModelContext(new)).first?.camera, 3)
    }

    func testCrewCueFromPoint() throws {
        let container = try ModelContainer(for: CuePoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let p = CuePoint(trackID: UUID(), time: 4, name: "Wide")
        p.camera = 2; p.shotNumber = "12A"; p.shotSize = "WS"; p.shotNote = "slow"; p.holdUntilNext = false
        ctx.insert(p)
        let c = CrewCue.cues(for: [p], types: CuePointType.defaults)[0]
        XCTAssertEqual(c.laneID, CuePointType.defaultID)
        XCTAssertEqual(c.camera, 2); XCTAssertEqual(c.shotNumber, "12A"); XCTAssertEqual(c.shotSize, "WS")
        XCTAssertEqual(c.shotNote, "slow"); XCTAssertFalse(c.holdUntilNext); XCTAssertEqual(c.cueID, "1")
    }

    func testDurationsRunToNextCutInSameLane() {
        let cues = [shot(10, cam: 1, "1"), shot(14, cam: 2, "2"), shot(5, cam: 9, "x", lane: lane2),
                    shot(20, cam: 1, "3"), shot(12, cam: 9, "y", lane: lane2)]
        let rows = ShotListBuilder.rows(from: cues, trackDuration: 30)
        XCTAssertEqual(rows.map(\.time), [5, 10, 12, 14, 20])
        let byNo = Dictionary(uniqueKeysWithValues: rows.map { ($0.shotNumber, $0) })
        XCTAssertEqual(byNo["1"]?.duration, 4)
        XCTAssertEqual(byNo["2"]?.duration, 6)
        XCTAssertEqual(byNo["3"]?.duration, 10)     // last: to the track end
        XCTAssertEqual(byNo["x"]?.duration, 7)      // its own lane only
        XCTAssertEqual(byNo["y"]?.duration, 18)
        XCTAssertEqual(byNo["3"]?.index, 3)
        XCTAssertEqual(ShotListBuilder.cameraTotals(rows.filter { $0.laneID == lane }), [1: 14, 2: 6])
    }

    func testNoHoldAndUnknownEnd() {
        let rows = ShotListBuilder.rows(from: [shot(1, cam: 1, "1", hold: false), shot(3, cam: 2, "2"), shot(3, cam: 3, "3")])
        XCTAssertNil(rows[0].duration)
        // Stacked at the same time: neither ends the other; no track length → open.
        XCTAssertNil(rows[1].duration); XCTAssertNil(rows[2].duration)
        XCTAssertEqual(ShotListBuilder.rows(from: [shot(1, cam: 1)], lanes: [lane2]).count, 0)
    }

    func testCSV() {
        var a = shot(5.0 + 2.0 / 30, cam: 2, "12")
        a.name = "Drop, \"big\""; a.shotNote = "push"
        let b = shot(8, cam: nil)
        let rows = ShotListBuilder.rows(from: [a, b])
        let csv = ShotListBuilder.csv(rows, clock: CuePointClock(start: Timecode(hours: 1, rate: .fps30)))
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Shot,Camera,Size,Timecode,Track time,Duration,Name,Note")
        XCTAssertEqual(lines[1], "\"12\",2,\"MS\",01:00:05:02,00:00:05:02,2.933,\"Drop, \"\"big\"\"\",\"push\"")
        XCTAssertEqual(lines[2], "\"2\",,\"MS\",01:00:08:00,00:00:08:00,,\"S\",\"\"")
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertEqual(ShotListBuilder.csvFileName(trackName: "A/B"), "A-B shotlist.csv")
    }
}
