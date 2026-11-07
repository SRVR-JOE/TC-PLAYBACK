import XCTest
import SwiftData
@testable import TCPlayback

final class ToolsCuePointEditorTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "cuePointTypes.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    // MARK: Type store

    func testStoreSeedsDefaultsAndPersistsThemStraightAway() {
        let s = CuePointTypeStore(defaults: defaults)
        XCTAssertEqual(s.types.map(\.name), CuePointType.defaults.map(\.name))
        XCTAssertNotNil(defaults.data(forKey: CuePointTypeStore.key), "seed must be saved so built-in ids stay stable")
        let again = CuePointTypeStore(defaults: defaults)
        XCTAssertEqual(again.types, s.types)
    }

    func testStoreEditsRoundTrip() {
        let s = CuePointTypeStore(defaults: defaults)
        let t = s.add(name: "Lasers")
        s.rename(t.id, to: "Laser")
        s.recolour(t.id, to: CuePointColor.purple.rawValue)
        s.setHidden(t.id, true)
        s.setLocked(s.types[1].id, true)
        let r = CuePointTypeStore(defaults: defaults)
        let back = r.type(for: t.id)
        XCTAssertEqual(back.name, "Laser")
        XCTAssertEqual(back.colorHex, CuePointColor.purple.rawValue)
        XCTAssertTrue(back.hidden)
        XCTAssertTrue(r.types[1].locked)
        XCTAssertFalse(r.visible.contains(where: { $0.id == t.id }))
        XCTAssertEqual(s.add(name: "Laser").name, "Laser 2", "names stay unique")
    }

    func testStoreReorder() {
        let s = CuePointTypeStore(defaults: defaults)
        let names = s.types.map(\.name)
        s.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(s.types.map(\.name), [names[3], names[0], names[1], names[2]])
        s.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(s.types.map(\.name), names)
    }

    func testNilAndUnknownTypeResolveToDefault() {
        let s = CuePointTypeStore(defaults: defaults)
        XCTAssertEqual(s.type(for: nil).id, CuePointType.defaultID)
        XCTAssertEqual(s.type(for: UUID()).id, CuePointType.defaultID)
    }

    func testDeleteMovesPointsToDefaultAndKeepsDefault() throws {
        let container = try ModelContainer(for: CuePoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let s = CuePointTypeStore(defaults: defaults)
        let lights = s.types[1]
        let track = UUID()
        let a = CuePoint(trackID: track, time: 1, name: "a"); a.typeID = lights.id
        let b = CuePoint(trackID: track, time: 2, name: "b")
        ctx.insert(a); ctx.insert(b); try ctx.save()

        s.delete(CuePointType.defaultID, context: ctx)
        XCTAssertTrue(s.types.contains(where: { $0.id == CuePointType.defaultID }), "default type can't be deleted")

        s.delete(lights.id, context: ctx)
        XCTAssertFalse(s.types.contains(where: { $0.id == lights.id }))
        XCTAssertNil(a.typeID)
        XCTAssertEqual(s.type(for: a.typeID).id, CuePointType.defaultID)
    }

    // MARK: Index / rows

    func testIndexNumbersPerTypeAndRowsFillContractFields() {
        let types = CuePointType.defaults
        let track = UUID()
        let p1 = CuePoint(trackID: track, time: 1, name: "one")
        let l1 = CuePoint(trackID: track, time: 2, name: "look"); l1.typeID = types[1].id; l1.fade = "+"
        let p2 = CuePoint(trackID: track, time: 3, name: "two"); p2.cueID = "7"; p2.fade = "1/2"
        let l2 = CuePoint(trackID: track, time: 6, name: "look 2"); l2.typeID = types[1].id; l2.colorHex = CuePointColor.red.rawValue
        let idx = CuePointIndex(points: [l2, p2, l1, p1], types: types)
        XCTAssertEqual(idx.number(of: p1), "1")
        XCTAssertEqual(idx.number(of: p2), "7")
        XCTAssertEqual(idx.number(of: l1), "1")
        XCTAssertEqual(idx.number(of: l2), "2")
        XCTAssertEqual(idx.colorHex(of: l1), types[1].colorHex)
        XCTAssertEqual(idx.colorHex(of: l2), CuePointColor.red.rawValue)

        let rows = CuePointRow.rows(for: [l2, p2, l1, p1], index: idx)
        XCTAssertEqual(rows.map(\.name), ["one", "look", "two", "look 2"])
        XCTAssertEqual(rows.map(\.typeName), ["Cue", "Lights", "Cue", "Lights"])
        XCTAssertEqual(rows[0].typeID, CuePointType.defaultID)
        XCTAssertEqual(rows[2].consoleCueID, "7")
        XCTAssertEqual(rows[2].number, 2)
        XCTAssertEqual(rows[1].fadeIn, 4, "+ runs to the next Lights point, not the next point")
        XCTAssertEqual(rows[2].fadeIn, 1); XCTAssertEqual(rows[2].fadeOut, 2)
        XCTAssertNil(rows[3].fadeIn)
        XCTAssertEqual(rows[3].colorHex, CuePointColor.red.rawValue)
    }

    // MARK: Numbering

    func testRenumber() {
        XCTAssertEqual(CuePointNumbering.renumbered(count: 4), ["1", "2", "3", "4"])
        XCTAssertEqual(CuePointNumbering.renumbered(count: 0), [])
    }

    func testRippleBetween() {
        XCTAssertEqual(CuePointNumbering.between("10", "11"), "10.5")
        XCTAssertEqual(CuePointNumbering.between("10", "12"), "11")
        XCTAssertEqual(CuePointNumbering.between("10", "10.5"), "10.3")
        XCTAssertEqual(CuePointNumbering.between("10.5", "11"), "10.8")
        XCTAssertEqual(CuePointNumbering.between("10", "10.05"), "10.03")
        XCTAssertEqual(CuePointNumbering.between("10", nil), "11", "after the last cue")
        XCTAssertEqual(CuePointNumbering.between("10.5", nil), "11")
        XCTAssertEqual(CuePointNumbering.between(nil, "1"), "0.5", "before the first cue")
        XCTAssertEqual(CuePointNumbering.between(nil, "5"), "1")
        XCTAssertEqual(CuePointNumbering.between(nil, nil), "")
        XCTAssertEqual(CuePointNumbering.between("11", "10"), "", "out of order: leave it to renumber")
        XCTAssertEqual(CuePointNumbering.between("intro", "outro"), "")
    }

    // MARK: Multi-select shift math

    func testShiftKeepsSpacingAndClamps() {
        let fps = 30.0
        XCTAssertEqual(CuePointSelectionMath.shifted([1, 2, 4], by: 1.0 / fps, duration: 10, fps: fps),
                       [1 + 1 / fps, 2 + 1 / fps, 4 + 1 / fps].map { ($0 * fps).rounded() / fps })
        // Can't push the earliest below zero: the whole block stops at 0.
        XCTAssertEqual(CuePointSelectionMath.shifted([0.5, 2], by: -3, duration: 10, fps: fps), [0, 1.5])
        // Or the latest past the end.
        XCTAssertEqual(CuePointSelectionMath.shifted([5, 9], by: 3, duration: 10, fps: fps), [6, 10])
        XCTAssertEqual(CuePointSelectionMath.clampedDelta(times: [], by: 3, duration: 10), 0)
    }

    func testMoveFirstToPlayhead() {
        let fps = 25.0
        XCTAssertEqual(CuePointSelectionMath.movingFirst([12, 10, 15], to: 20, duration: 100, fps: fps), [22, 20, 25])
        XCTAssertEqual(CuePointSelectionMath.movingFirst([10, 30], to: 90, duration: 100, fps: fps), [80, 100], "clamped: the last mark stops at the end")
        XCTAssertEqual(CuePointSelectionMath.movingFirst([10, 11], to: 3.01, duration: 100, fps: fps), [3, 4], "snapped to frames")
    }

    // MARK: Live marking timing

    func testPlayheadExtrapolatesBetweenEngineUpdatesWhilePlaying() {
        // Engine said 10.000 s at t=100.000; touch-down lands 20 ms later.
        XCTAssertEqual(CueMarkTiming.playhead(reported: 10, reportedAt: 100, now: 100.02, playing: true), 10.02, accuracy: 1e-9)
        // Parked: no extrapolation.
        XCTAssertEqual(CueMarkTiming.playhead(reported: 10, reportedAt: 100, now: 100.02, playing: false), 10)
        // A stalled engine can't run the mark away (capped at 100 ms).
        XCTAssertEqual(CueMarkTiming.playhead(reported: 10, reportedAt: 100, now: 105, playing: true), 10.1, accuracy: 1e-9)
        // Unknown stamp: use the reported value.
        XCTAssertEqual(CueMarkTiming.playhead(reported: 10, reportedAt: 0, now: 105, playing: true), 10)
    }

    func testMarkTimeSubtractsTapAndSpeakerDelayOnlyWhilePlaying() {
        let fps = 30.0
        // 10 s − 100 ms tap delay − 0 latency = 9.9 s → frame 297 → 9.9 s.
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 10, playing: true, tapDelayMs: -100, outputLatency: 0, fps: fps, duration: 60),
                       297 / fps, accuracy: 1e-9)
        // Plus 200 ms Bluetooth-style delay: 9.7 s → frame 291.
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 10, playing: true, tapDelayMs: -100, outputLatency: 0.2, fps: fps, duration: 60),
                       291 / fps, accuracy: 1e-9)
        // Positive "delay" is ignored (the setting is 0 to −150 ms).
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 10, playing: true, tapDelayMs: 50, outputLatency: 0, fps: fps, duration: 60), 10)
        // Parked: exactly the playhead, whatever the settings.
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 10, playing: false, tapDelayMs: -150, outputLatency: 0.2, fps: fps, duration: 60), 10)
        // Clamped to the track and snapped.
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 0.05, playing: true, tapDelayMs: -150, outputLatency: 0, fps: fps, duration: 60), 0)
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 61, playing: false, tapDelayMs: 0, outputLatency: 0, fps: fps, duration: 60), 60)
        XCTAssertEqual(CueMarkTiming.markTime(playhead: 1.0 + 0.4 / fps, playing: false, tapDelayMs: 0, outputLatency: 0, fps: fps, duration: 60), 1)
    }

    func testTouchDownFiresOnTouchDownNotRelease() {
        var fired = 0
        let area = TouchDownArea(label: "Mark", action: { fired += 1 })
        let control = TouchDownArea.Control()
        control.action = area.action
        control.addTarget(control, action: #selector(TouchDownArea.Control.down), for: .touchDown)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(fired, 0, "release must not mark")
        control.sendActions(for: .touchDown)
        XCTAssertEqual(fired, 1)
        // Rapid taps each mark.
        for _ in 0..<8 { control.sendActions(for: .touchDown) }
        XCTAssertEqual(fired, 9)
    }

    func testSamplerStamps() {
        let s = PlayheadSampler()
        s.note(4.5, at: 12)
        XCTAssertEqual(s.value, 4.5); XCTAssertEqual(s.stamp, 12)
    }

    // MARK: Labels

    func testLabelNumbering() {
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: []), "Chorus")
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: ["Verse"]), "Chorus")
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: ["Chorus"]), "Chorus 2")
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: ["Chorus", "Chorus 2"]), "Chorus 3")
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: ["chorus 4"]), "Chorus 5", "case-insensitive, after the highest")
        XCTAssertEqual(CueLabelNaming.numbered("Chorus", existing: ["Choruses", "Chorus 2b", "Pre-chorus"]), "Chorus")
        XCTAssertEqual(CueLabelNaming.numbered(" Drop ", existing: ["Drop"]), "Drop 2")
    }

    func testApplyLabelToSeveral() {
        XCTAssertEqual(CueLabelNaming.apply("Chorus", count: 3, otherNames: ["Chorus"], numberRepeats: true),
                       ["Chorus 2", "Chorus 3", "Chorus 4"])
        XCTAssertEqual(CueLabelNaming.apply("Hit", count: 2, otherNames: [], numberRepeats: true), ["Hit", "Hit 2"])
        XCTAssertEqual(CueLabelNaming.apply("Hit", count: 2, otherNames: ["Hit"], numberRepeats: false), ["Hit", "Hit"])
    }

    func testLabelPresetStore() {
        let s = CueLabelPresetStore(defaults: defaults)
        XCTAssertEqual(s.labels.first, "Intro")
        XCTAssertEqual(s.labels.count, 15)
        s.add("Kabuki"); s.add("kabuki"); s.add("  ")
        XCTAssertEqual(s.labels.last, "Kabuki")
        XCTAssertEqual(s.labels.count, 16)
        s.move(fromOffsets: IndexSet(integer: 15), toOffset: 0)
        s.remove(atOffsets: IndexSet(integer: 1))
        let r = CueLabelPresetStore(defaults: defaults)
        XCTAssertEqual(r.labels.prefix(2), ["Kabuki", "Verse"])
    }
}
