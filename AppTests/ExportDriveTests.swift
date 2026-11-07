import XCTest
@testable import TCPlayback

@MainActor
final class ExportDriveTests: XCTestCase {
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ExportDriveTests-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testStartsNotChosen() {
        XCTAssertEqual(ExportDrive(defaults: defaults).state, .notChosen)
    }

    func testChooseThenSaveCopiesAndReplaces() throws {
        let drive = ExportDrive(defaults: defaults)
        try drive.choose(root)
        XCTAssertTrue(drive.isReady)
        let a = try file("Song_cue_table.txt", "one")
        XCTAssertEqual(try drive.save([a]), ["Song_cue_table.txt"])
        let b = try file("Song_cue_table.txt", "two")
        try drive.save([b])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Song_cue_table.txt"), encoding: .utf8), "two")
    }

    func testRemembersChoiceAcrossLaunches() throws {
        try ExportDrive(defaults: defaults).choose(root)
        let again = ExportDrive(defaults: defaults)
        XCTAssertTrue(again.isReady)
        XCTAssertTrue(again.name.hasSuffix(root.lastPathComponent), again.name)
    }

    func testUnpluggedDriveIsMissingAndSaveFails() throws {
        let drive = ExportDrive(defaults: defaults)
        try drive.choose(root)
        try FileManager.default.removeItem(at: root)
        drive.refresh()
        XCTAssertEqual(drive.state, .missing(name: drive.name))
        XCTAssertFalse(drive.isReady)
        XCTAssertThrowsError(try drive.save([try file("x.txt", "x")]))
    }

    func testItemSaveReportsFeedback() throws {
        let drive = ExportDrive(defaults: defaults)
        try drive.choose(root)
        let u = try file("Show.tcshow", "zip")
        drive.save(ExportDriveItem(id: "show", title: "Show") { [u] })
        XCTAssertEqual(drive.feedback?.ok, true)
        XCTAssertTrue(drive.feedback?.text.contains("Show.tcshow") ?? false)
    }

    func testForget() throws {
        let drive = ExportDrive(defaults: defaults)
        try drive.choose(root)
        drive.forget()
        XCTAssertEqual(drive.state, .notChosen)
    }

    func testSubfolderIsCreated() throws {
        let drive = ExportDrive(defaults: defaults)
        try drive.choose(root)
        let u = try file("Song_cue_table.txt", "t")
        try drive.save([u], subfolder: CueTableExport.disguiseFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "objects/table/Song_cue_table.txt").path))
    }
}
