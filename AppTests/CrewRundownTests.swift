import XCTest
@testable import TCPlayback

final class CrewRundownTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()
    var cues: [RundownSourceCue] {
        [RundownSourceCue(id: a, title: "Opener", trackID: UUID(), duration: 180),
         RundownSourceCue(id: b, title: "Ballad", trackID: UUID(), duration: 240),
         RundownSourceCue(id: c, title: "Closer", trackID: UUID(), duration: 200)]
    }
    func rundown(_ m: RundownMetadata = .init()) -> Rundown {
        Rundown.derive(playlistID: UUID(), name: "Show", cues: cues, metadata: m)
    }

    func testDeriveUsesPlaylistOrderAndMetadata() {
        var m = RundownMetadata()
        m.acts[b] = ActMetadata(plannedDuration: 250, notes: "key change", title: "Ballad (acoustic)")
        m.acts[UUID()] = ActMetadata(skip: true)          // orphan: ignored
        let r = rundown(m)
        XCTAssertEqual(r.acts.map(\.id), [a, b, c])
        XCTAssertEqual(r.acts[1].title, "Ballad (acoustic)")
        XCTAssertEqual(r.acts[1].plannedDuration, 250)
        XCTAssertEqual(r.acts[0].plannedDuration, 180)
        XCTAssertEqual(r.acts[1].notes, "key change")
    }

    func testReorderKeepsNewCues() {
        let r = rundown()
        var m = Rundown.reordered(RundownMetadata(), rundown: r, from: 2, to: 0)
        XCTAssertEqual(rundown(m).acts.map(\.id), [c, a, b])
        m.order = [b]   // cues not listed follow in playlist order
        XCTAssertEqual(rundown(m).acts.map(\.id), [b, a, c])
    }

    func testPlannedScheduleChainsAndSkips() {
        var s = RundownTimer.status(rundown(), actuals: [:], now: 0)
        XCTAssertEqual(s.acts.map(\.plannedStart), [0, 180, 420])
        XCTAssertEqual(s.plannedEnd, 620)
        XCTAssertEqual(s.projectedEnd, 620)
        XCTAssertEqual(s.overUnder, 0)
        XCTAssertEqual(s.runningTime, 0)

        let skipped = Rundown.settingSkip(RundownMetadata(), act: b, true)
        s = RundownTimer.status(rundown(skipped), actuals: [:], now: 0)
        XCTAssertEqual(s.acts[1].state, .skipped)
        XCTAssertEqual(s.acts[2].plannedStart, 180)
        XCTAssertEqual(s.plannedEnd, 380)
    }

    func testExplicitPlannedStartLeavesGap() {
        var m = RundownMetadata(); m.acts[c] = ActMetadata(plannedStart: 600)
        let s = RundownTimer.status(rundown(m), actuals: [:], now: 0)
        XCTAssertEqual(s.acts[2].plannedStart, 600)
        XCTAssertEqual(s.acts[2].projectedStart, 600)
        XCTAssertEqual(s.plannedEnd, 800)
    }

    func testActualsOverUnderAndProjection() {
        // Opener ran 200 s (20 over), ballad started 10 s after it ended and is 100 s in.
        let actuals: [UUID: ActActual] = [a: ActActual(start: 0, end: 200), b: ActActual(start: 210, end: nil)]
        let s = RundownTimer.status(rundown(), actuals: actuals, now: 310)
        XCTAssertEqual(s.acts[0].state, .done)
        XCTAssertEqual(s.acts[0].overUnder, 20)
        XCTAssertEqual(s.acts[1].state, .running)
        XCTAssertEqual(s.acts[1].actualDuration, 100)
        XCTAssertEqual(s.acts[1].startDrift, 30)
        XCTAssertNil(s.acts[1].overUnder)
        XCTAssertEqual(s.acts[2].projectedStart, 450)   // 210 + planned 240
        XCTAssertEqual(s.projectedEnd, 650)
        XCTAssertEqual(s.overUnder, 30)
        XCTAssertEqual(s.runningTime, 310)
        XCTAssertEqual(s.current?.id, b)
        XCTAssertEqual(s.next?.id, c)

        // Running act past its planned length pushes everything after it.
        let late = RundownTimer.status(rundown(), actuals: actuals, now: 500)
        XCTAssertEqual(late.acts[2].projectedStart, 500)
        XCTAssertEqual(late.overUnder, 80)
    }

    func testPendingActCannotStartInThePast() {
        // Opener done early at 150; at 170 nothing is running: the next act is projected from now.
        let s = RundownTimer.status(rundown(), actuals: [a: ActActual(start: 0, end: 150)], now: 170)
        XCTAssertEqual(s.acts[1].projectedStart, 170)
        XCTAssertEqual(s.acts[1].startDrift, -10)
        XCTAssertEqual(s.overUnder, -10)
        let s2 = RundownTimer.status(rundown(), actuals: [a: ActActual(start: 0, end: 150)], now: 200)
        XCTAssertEqual(s2.acts[1].projectedStart, 200)
        XCTAssertEqual(s2.overUnder, 20)
    }

    func testSkippedButPlayedCountsAsPlayed() {
        let m = Rundown.settingSkip(RundownMetadata(), act: a, true)
        let s = RundownTimer.status(rundown(m), actuals: [a: ActActual(start: 0, end: 100)], now: 100)
        XCTAssertEqual(s.acts[0].state, .done)
    }

    func testStoreRoundTrip() {
        let d = UserDefaults(suiteName: "crew.rundown.test.\(UUID())")!
        let pid = UUID()
        XCTAssertEqual(RundownStore.load(playlistID: pid, defaults: d), RundownMetadata())
        var m = RundownMetadata(); m.acts[a] = ActMetadata(plannedStart: 5, skip: true); m.order = [c, a]
        RundownStore.save(m, playlistID: pid, defaults: d)
        XCTAssertEqual(RundownStore.load(playlistID: pid, defaults: d), m)
    }
}
