import XCTest
@testable import TCPlayback

final class CrewRoleTests: XCTestCase {
    let shots = UUID(), lights = UUID(), other = UUID()

    func cue(_ t: TimeInterval, _ lane: UUID, cam: Int? = nil, _ name: String = "") -> CrewCue {
        CrewCue(id: UUID(), time: t, name: name, laneID: lane, camera: cam)
    }

    func testLaneRoleMatchesItsLanesOnly() {
        let role = CrewRole(name: "LX", kind: .lighting, colorHex: "#FFFFFF", laneIDs: [lights])
        XCTAssertTrue(role.matches(cue(1, lights)))
        XCTAssertFalse(role.matches(cue(1, shots)))
    }

    func testCameraRoleMatchesItsCameraInItsLane() {
        let cam3 = CrewRole(name: "Cam 3", kind: .camera, cameraNumber: 3, colorHex: "#FFFFFF", laneIDs: [shots])
        XCTAssertTrue(cam3.matches(cue(1, shots, cam: 3)))
        XCTAssertFalse(cam3.matches(cue(1, shots, cam: 2)))
        XCTAssertFalse(cam3.matches(cue(1, shots)))
        XCTAssertFalse(cam3.matches(cue(1, other, cam: 3)))
        let anyLane = CrewRole(name: "Cam 3", kind: .camera, cameraNumber: 3, colorHex: "#FFFFFF")
        XCTAssertTrue(anyLane.matches(cue(1, other, cam: 3)))
        let nothing = CrewRole(name: "Empty", kind: .custom, colorHex: "#FFFFFF")
        XCTAssertFalse(nothing.matches(cue(1, other)))
    }

    func testWindowNowNextAfter() {
        let role = CrewRole(name: "Cam 1", kind: .camera, cameraNumber: 1, colorHex: "#FFFFFF", laneIDs: [shots])
        let cues = [cue(10, shots, cam: 1, "a"), cue(5, shots, cam: 2, "x"), cue(20, shots, cam: 1, "b"),
                    cue(30, shots, cam: 1, "c"), cue(40, shots, cam: 1, "d"), cue(15, lights, "lx")]
        var w = CrewLaneFilter.window(for: role, cues: cues, at: 0)
        XCTAssertNil(w.now); XCTAssertEqual(w.next?.name, "a"); XCTAssertEqual(w.after?.name, "b")
        XCTAssertEqual(w.untilNext, 10)
        w = CrewLaneFilter.window(for: role, cues: cues, at: 10)   // exactly on a cue = now
        XCTAssertEqual(w.now?.name, "a"); XCTAssertEqual(w.next?.name, "b"); XCTAssertEqual(w.after?.name, "c")
        w = CrewLaneFilter.window(for: role, cues: cues, at: 35)
        XCTAssertEqual(w.now?.name, "c"); XCTAssertEqual(w.next?.name, "d"); XCTAssertNil(w.after)
        w = CrewLaneFilter.window(for: role, cues: cues, at: 99)
        XCTAssertEqual(w.now?.name, "d"); XCTAssertNil(w.next); XCTAssertNil(w.untilNext)
    }

    func testStorePersistsAndPrunes() {
        let d = UserDefaults(suiteName: "crew.roles.test.\(UUID())")!
        let s = CrewRoleStore(defaults: d)
        XCTAssertTrue(s.roles.isEmpty)
        let r = s.add(CrewRole(name: "SFX", kind: .sfx, colorHex: "#E5484D", laneIDs: [lights, other]))
        var changed = r; changed.name = "Pyro"; s.update(changed)
        let reloaded = CrewRoleStore(defaults: d)
        XCTAssertEqual(reloaded.roles, [changed])
        reloaded.prune(validLaneIDs: [lights])
        XCTAssertEqual(CrewRoleStore(defaults: d).roles.first?.laneIDs, [lights])
        reloaded.delete(r.id)
        XCTAssertTrue(CrewRoleStore(defaults: d).roles.isEmpty)
    }

    func testRoleDecodesWithMissingFields() throws {
        let json = #"{"name":"Old","kind":"weird"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(CrewRole.self, from: json)
        XCTAssertEqual(r.name, "Old"); XCTAssertEqual(r.kind, .custom); XCTAssertEqual(r.laneIDs, [])
    }

    func testStarterRolesPickLanesByName() {
        let types = [CuePointType(name: "Shots", colorHex: "#FFFFFF"), CuePointType(name: "Lights", colorHex: "#FFFFFF"),
                     CuePointType(name: "Special FX", colorHex: "#FFFFFF")]
        let roles = CrewRoleStore.starterRoles(types: types, cameras: 2)
        XCTAssertEqual(roles.map(\.name), ["Cam 1", "Cam 2", "Lighting", "Video", "SFX"])
        XCTAssertEqual(roles[0].laneIDs, [types[0].id])
        XCTAssertEqual(roles[2].laneIDs, [types[1].id])
        XCTAssertEqual(roles[4].laneIDs, [types[2].id])
        XCTAssertEqual(roles[3].laneIDs, [])
    }
}
