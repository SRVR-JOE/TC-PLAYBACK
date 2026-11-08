import UIKit
import XCTest
@testable import TCPlayback

/// Camera directions (keywords and ready-made lines) and the shot reference library.
@MainActor
final class ToolsShotLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = URL.temporaryDirectory.appending(path: "shots-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testDirectionsFillInTheSubject() {
        let d = CameraDirection(template: "When {subject}'s hands go up, zoom out to get them in.", category: .moments)
        XCTAssertEqual(d.text(subject: "Macklemore"), "When Macklemore's hands go up, zoom out to get them in.")
        XCTAssertEqual(CameraDirection(template: "{subject} all night.", category: .follow).text(subject: " "), "The artist all night.")
        XCTAssertTrue(CameraDirections.directions.allSatisfy { !$0.text(subject: "X").contains("{") })
        XCTAssertEqual(Set(CameraDirections.directions.map(\.id)).count, CameraDirections.directions.count, "no duplicate lines")
        XCTAssertEqual(Set(CameraDirections.terms.map(\.id)).count, CameraDirections.terms.count, "no duplicate keywords")
        for c in CameraTerm.Category.allCases { XCTAssertFalse(CameraDirections.terms(in: c).isEmpty, c.label) }
        XCTAssertEqual(CameraDirections.terms.first { $0.abbr == "MCU" }?.display, "Medium close-up (MCU)")
    }

    func testAppendingToAMission() {
        XCTAssertEqual(CameraDirections.append("Crowd shots between songs.", to: ""), "Crowd shots between songs.")
        XCTAssertEqual(CameraDirections.append("Hold.", to: "Macklemore all night.\n"), "Macklemore all night.\nHold.")
        XCTAssertEqual(CameraDirections.appendKeyword("MCU", to: "Stay"), "Stay MCU")
        XCTAssertEqual(CameraDirections.appendKeyword("Push in", to: ""), "Push in")
    }

    func testLibrarySeedsEditsAndPersists() throws {
        let a = ShotLibraryStore(directory: dir)
        XCTAssertEqual(a.shots.count, ShotReference.defaults.count)
        var s = ShotReference(name: "Pit low", abbr: "PIT", description: "From the pit, looking up.", framing: .lowAngle)
        a.save(s)
        s.description = "Pit, looking up at the artist."
        a.save(s)
        a.delete(a.shots[0])
        let b = ShotLibraryStore(directory: dir)
        XCTAssertEqual(b.shots.count, ShotReference.defaults.count)
        XCTAssertEqual(b.shots.last?.description, "Pit, looking up at the artist.")
        XCTAssertFalse(b.shots.contains { $0.name == "Extreme close-up" })
        b.restoreDefaults()
        XCTAssertTrue(b.shots.contains { $0.name == "Extreme close-up" })
        XCTAssertEqual(b.shots.filter { $0.name == "Close-up" }.count, 1, "restore doesn't duplicate")
    }

    func testPhotoIsScaledStoredAndRemoved() throws {
        let store = ShotLibraryStore(directory: dir)
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 2250)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 4000, height: 2250))
        }
        let shot = store.shots[2]
        let withPhoto = try store.setPhoto(big.pngData()!, for: shot)
        let url = try XCTUnwrap(store.imageURL(withPhoto))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let img = try XCTUnwrap(store.image(withPhoto))
        XCTAssertLessThanOrEqual(max(img.size.width * img.scale, img.size.height * img.scale), 1600)
        XCTAssertEqual(ShotLibraryStore(directory: dir).shots[2].imageFile, withPhoto.imageFile)
        XCTAssertThrowsError(try store.setPhoto(Data("nope".utf8), for: withPhoto))
        let cleared = store.removePhoto(withPhoto)
        XCTAssertNil(cleared.imageFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEveryPersonFramingHasAWindowTighterToWider() {
        let order: [ShotFraming] = [.ecu, .cu, .mcu, .ms, .cowboy, .wide, .extremeWide]
        let heights = order.compactMap { ShotFramingDiagram.window($0)?.height }
        XCTAssertEqual(heights.count, order.count)
        XCTAssertEqual(heights, heights.sorted(), "each size is wider than the one before")
        // The face is in every tight frame.
        for f in [ShotFraming.ecu, .cu, .mcu, .ms] {
            let w = ShotFramingDiagram.window(f)!
            XCTAssertTrue((w.top - w.height)...w.top ~= 1.64, f.label)
        }
    }

    func testTolerantDecode() throws {
        let s = try JSONDecoder().decode(ShotReference.self, from: Data(#"{"name":"Jib sweep","framing":"spiral"}"#.utf8))
        XCTAssertEqual(s.name, "Jib sweep")
        XCTAssertEqual(s.framing, .none)
        XCTAssertNil(s.imageFile)
    }
}
