import PDFKit
import SwiftData
import XCTest
@testable import TCPlayback

/// The Cameras page model: per-show camera briefs, show export/import, the one-time Macklemore
/// seed, the PDF, and the caller's keys reading names from the brief.
@MainActor
final class ToolsCameraBriefTests: LibraryTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = URL.temporaryDirectory.appending(path: "briefs-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }
    private func store() -> CameraBriefStore { CameraBriefStore(directory: dir, defaults: defaults) }

    func testModelRoundTripAndTolerantDecode() throws {
        var b = CameraBrief.macklemore
        b.cameras[0].operatorName = "Dani"; b.cameras[0].position = "Pit"; b.cameras[0].kind = .steadicam
        b.cameras[0].lens = "24–70"; b.cameras[0].colorHex = CuePointColor.amber.rawValue; b.cameras[0].name = "Pit cam"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(CameraBrief.self, from: enc.encode(b))
        XCTAssertEqual(back.cameras, b.cameras)
        XCTAssertEqual(back.cameras[0].callName, "Pit cam")
        XCTAssertEqual(back.cameras[1].callName, "Camera 2", "blank name calls it by number")
        XCTAssertEqual(back.cameras[0].detailLine, "Steadicam · Pit · Dani · 24–70")
        // Fields this version doesn't know or doesn't have yet don't break a brief.
        let partial = try dec.decode(CameraBrief.self, from: Data(#"{"cameras":[{"number":7,"name":"Jib","kind":"crane","future":1}]}"#.utf8))
        XCTAssertEqual(partial.cameras.first?.callName, "Jib")
        XCTAssertEqual(partial.cameras.first?.kind, .other)
        XCTAssertEqual(partial.cameras.first?.mission, "")
    }

    func testStorePersistsPerPlaylist() {
        let a = UUID(), b = UUID()
        let s1 = store()
        XCTAssertFalse(s1.hasBrief(a))
        s1.set(CameraBrief.macklemore, for: a)
        s1.rename(number: 7, to: "Jib", in: b)
        let s2 = store()   // relaunch
        XCTAssertEqual(s2.brief(a).cameras.count, 4)
        XCTAssertEqual(s2.brief(b).cameras.map(\.callName), ["Jib"])
        XCTAssertEqual(s2.brief(b).keyNames[6], "Jib")
        XCTAssertEqual(s2.brief(b).keyNames[0], "Camera 1")
        XCTAssertTrue(s2.brief(UUID()).cameras.isEmpty)
    }

    func testCallerKeysUseBriefNames() {
        let briefs = store()
        let keys = CueCameraPresetStore(defaults: defaults, briefs: briefs)
        briefs.set(CameraBrief(cameras: [BriefCamera(number: 1, name: "Pit", mission: "Macklemore all night"),
                                         BriefCamera(number: 7, name: "Jib")]), for: briefs.currentID)
        XCTAssertEqual(keys.presets.cameras[0], "Pit")
        XCTAssertEqual(keys.presets.cameras[6], "Jib")
        XCTAssertEqual(keys.presets.cameras[1], "Camera 2")
        XCTAssertEqual(keys.presets.customNames, ["Pit", "Jib"])
        XCTAssertEqual(keys.briefCamera(0)?.mission, "Macklemore all night")
        var told = 0
        keys.onChange = { _ in told += 1 }
        keys.rename(1, to: "Wide")
        XCTAssertEqual(briefs.brief(briefs.currentID).camera(number: 2)?.name, "Wide", "renaming a key edits the brief")
        XCTAssertEqual(told, 1)
        keys.addShot("Crash zoom")
        XCTAssertEqual(keys.presets.shots.last, "Crash zoom")
    }

    func testMacklemoreSeedRunsOnceAndNeverOverwrites() {
        let mack = UUID(), other = UUID()
        let s = store()
        XCTAssertNil(s.seedMacklemoreOnce(playlists: [(other, "Arena")]), "no Macklemore show: nothing yet")
        XCTAssertEqual(s.seedMacklemoreOnce(playlists: [(other, "Arena"), (mack, " macklemore ")]), mack)
        let b = s.brief(mack)
        XCTAssertEqual(b.cameras.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(b.cameras.map(\.subject), Array(repeating: "Macklemore", count: 4))
        XCTAssertEqual(b.cameras[0].mission, "Macklemore all night. Mid to tight shots. When his hands go up, zoom out to get them in.")
        XCTAssertEqual(b.cameras[3].mission, "Macklemore, horns, background singers and DJ.")
        // The operator empties it; a later launch leaves it alone.
        s.set(CameraBrief(), for: mack)
        let later = store()
        XCTAssertNil(later.seedMacklemoreOnce(playlists: [(mack, "Macklemore")]))
        XCTAssertTrue(later.brief(mack).cameras.isEmpty)
    }

    func testMacklemoreSeedLeavesAnExistingBrief() {
        let mack = UUID()
        let s = store()
        s.set(CameraBrief(cameras: [BriefCamera(number: 9, name: "Drone")]), for: mack)
        XCTAssertNil(s.seedMacklemoreOnce(playlists: [(mack, "MACKLEMORE")]))
        XCTAssertEqual(s.brief(mack).cameras.map(\.callName), ["Drone"])
        XCTAssertTrue(defaults.bool(forKey: CameraBriefStore.macklemoreSeededKey))
    }

    func testShowExportImportCarriesTheBrief() async throws {
        let briefs = store()
        let p = PlaylistEditor.createPlaylist(named: "Macklemore", context: context)
        _ = PlaylistEditor.appendGenerator(to: p, context: context)
        var b = CameraBrief.macklemore
        b.cameras[2].name = "Jib"; b.cameras[2].kind = .jib
        briefs.set(b, for: p.id)
        let zip = try ShowPackage.export(p, briefs: briefs)
        defer { try? FileManager.default.removeItem(at: zip) }
        let imported = try await ShowPackage.importShow(from: zip, context: context, briefs: briefs)
        XCTAssertNotEqual(imported.id, p.id)
        XCTAssertEqual(briefs.brief(imported.id).cameras, b.cameras, "the copy gets its own brief")

        // A show without a brief (as every older file is) imports with none.
        let plain = PlaylistEditor.createPlaylist(named: "Plain", context: context)
        _ = PlaylistEditor.appendGenerator(to: plain, context: context)
        let zip2 = try ShowPackage.export(plain, briefs: briefs)
        defer { try? FileManager.default.removeItem(at: zip2) }
        let again = try await ShowPackage.importShow(from: zip2, context: context, briefs: briefs)
        XCTAssertFalse(briefs.hasBrief(again.id))
    }

    func testOlderShowFileDecodes() throws {
        let old = #"{"format":"tcshow","version":1,"exportedAt":"2026-05-01T10:00:00Z","playlist":{"id":"6E1B1E62-6C55-4F0B-9E43-4C3B7C0A0A01","name":"Old"},"tracks":[],"cues":[]}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let f = try dec.decode(ShowFile.self, from: Data(old.utf8))
        XCTAssertEqual(f.playlist.name, "Old")
        XCTAssertNil(f.cameraBrief)
    }

    func testPDFHasPages() throws {
        let one = CameraBriefPDF.data(brief: CameraBrief.macklemore, showName: "Macklemore")
        XCTAssertEqual(String(decoding: one.prefix(4), as: UTF8.self), "%PDF")
        let doc = try XCTUnwrap(PDFDocument(data: one))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertTrue(doc.string?.contains("When his hands go up") ?? false)
        XCTAssertTrue(doc.string?.contains("Macklemore") ?? false)
        // Long missions flow onto more pages.
        let long = String(repeating: "Stay wide on the band, find the horns on the solo, back to the lead for the hook. ", count: 6)
        let many = CameraBrief(cameras: (1...12).map { BriefCamera(number: $0, subject: "Band", mission: long) })
        XCTAssertGreaterThan(PDFDocument(data: CameraBriefPDF.data(brief: many, showName: "Big"))?.pageCount ?? 0, 2)
        let url = try CameraBriefPDF.makeURL(brief: CameraBrief.macklemore, showName: "Mack/lemore")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(PDFDocument(data: CameraBriefPDF.data(brief: CameraBrief(), showName: ""))?.pageCount, 1, "an empty brief still prints")
    }
}
