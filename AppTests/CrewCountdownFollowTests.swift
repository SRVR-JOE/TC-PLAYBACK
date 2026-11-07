import XCTest
@testable import TCPlayback

final class CrewCountdownTests: XCTestCase {
    let lane = UUID()
    lazy var role = CrewRole(name: "LX", kind: .lighting, colorHex: "#FFFFFF", laneIDs: [lane])
    lazy var cues = [10.0, 30, 100].map { CrewCue(id: UUID(), time: $0, name: "Q\(Int($0))", laneID: lane) }

    func testSecondsAndProgress() {
        var m = CountdownModel(role: role, cues: cues, playhead: 25, barWindow: 10)
        XCTAssertEqual(m.secondsToNext, 5)
        XCTAssertEqual(m.window.next?.name, "Q30")
        XCTAssertEqual(m.progress, 0.5, accuracy: 1e-9)       // bar covers 20…30
        m = CountdownModel(role: role, cues: cues, playhead: 12, barWindow: 10)
        XCTAssertEqual(m.progress, 0, accuracy: 1e-9)         // before the bar starts
        m = CountdownModel(role: role, cues: cues, playhead: 5, barWindow: 30)
        XCTAssertEqual(m.progress, 0.5, accuracy: 1e-9)       // from track start (0) to 10
        m = CountdownModel(role: role, cues: cues, playhead: 200)
        XCTAssertNil(m.secondsToNext); XCTAssertEqual(m.progress, 1); XCTAssertEqual(m.spoken, [])
        m = CountdownModel(role: role, cues: [], playhead: 1)
        XCTAssertEqual(m.progress, 0)
    }

    func testBarsBeatsWithGrid() {
        let grid = BeatGrid(bpm: 120, firstBeat: 0)  // 0.5 s beats, 2 s bars
        var m = CountdownModel(role: role, cues: cues, playhead: 25, grid: grid)
        XCTAssertEqual(m.barsBeatsToNext, BarsBeats(bars: 2, beats: 2, totalBeats: 10))
        m = CountdownModel(role: role, cues: cues, playhead: 29.9, grid: grid)
        XCTAssertEqual(m.barsBeatsToNext?.totalBeats, 1)
        XCTAssertNil(CountdownModel(role: role, cues: cues, playhead: 25).barsBeatsToNext)
    }

    func testSpokenSchedule() {
        let m = CountdownModel(role: role, cues: cues, playhead: 20)
        XCTAssertEqual(m.spoken, [SpokenCount(word: "3", time: 27), SpokenCount(word: "2", time: 28), SpokenCount(word: "1", time: 29)])
        let g = CountdownModel(role: role, cues: cues, playhead: 20, grid: BeatGrid(bpm: 120, firstBeat: 0))
        XCTAssertEqual(g.spoken.map(\.time), [28.5, 29, 29.5])
    }

    func testCallerSpeaksOnceAndNotOnSeek() {
        let schedule = CountdownModel.schedule(before: 30, grid: nil)
        var caller = CountdownCaller()
        let speaker = SilentCrewSpeaker()
        var t = 26.0
        while t < 30.5 { caller.advance(to: t, schedule: schedule, speaker: speaker); t += 1.0 / 60 }
        XCTAssertEqual(speaker.spoken, ["3", "2", "1"])
        var c2 = CountdownCaller()
        _ = c2.advance(to: 20, schedule: schedule)
        XCTAssertEqual(c2.advance(to: 28.5, schedule: schedule), [])   // a seek over the counts
        XCTAssertEqual(c2.advance(to: 28.0, schedule: schedule), [])   // backwards
    }
}

final class CrewFollowTests: XCTestCase {
    func following(at host: TimeInterval = 0, track: TimeInterval = 10) -> FollowMachine {
        var m = FollowMachine(dropoutAfter: 0.1, freewheelLimit: 1)
        m.ltc(trackTime: track, host: host)
        return m
    }

    func testStartsLostThenFollows() {
        var m = FollowMachine()
        XCTAssertEqual(m.state, .lost)
        m.tick(host: 5)
        XCTAssertEqual(m.state, .lost)
        m.ltc(trackTime: 3, host: 5)
        XCTAssertEqual(m.state, .following)
        XCTAssertEqual(m.playhead(at: 5.5), 3.5, accuracy: 1e-9)
    }

    func testDropoutFreewheelThenLostThenReturn() {
        var m = following()
        m.tick(host: 0.05)
        XCTAssertEqual(m.state, .following)
        m.tick(host: 0.2)
        XCTAssertEqual(m.state, .freewheel(since: 0))
        XCTAssertFalse(m.ltcPresent)
        XCTAssertEqual(m.playhead(at: 0.6), 10.6, accuracy: 1e-9)        // keeps running
        m.tick(host: 1.05)
        XCTAssertEqual(m.state, .freewheel(since: 0))
        m.tick(host: 1.2)
        XCTAssertEqual(m.state, .lost)
        XCTAssertEqual(m.playhead(at: 1.2), 11.1, accuracy: 1e-9)        // held where freewheel ended
        XCTAssertEqual(m.playhead(at: 9), 11.1, accuracy: 1e-9)
        m.ltc(trackTime: 40, host: 9)                                       // LTC back (elsewhere)
        XCTAssertEqual(m.state, .following)
        XCTAssertEqual(m.playhead(at: 9.5), 40.5, accuracy: 1e-9)
    }

    func testReturnDuringFreewheel() {
        var m = following()
        m.tick(host: 0.5)
        XCTAssertEqual(m.state, .freewheel(since: 0))
        m.ltc(trackTime: 10.5, host: 0.5)
        XCTAssertEqual(m.state, .following)
    }

    func testOneTickPastEverythingGoesStraightToLost() {
        var m = following()
        m.tick(host: 5)
        XCTAssertEqual(m.state, .lost)
        XCTAssertEqual(m.playhead(at: 5), 11.1, accuracy: 1e-9)
    }

    func testManualStepAndResume() {
        let cues: [TimeInterval] = [5, 12, 20]
        var m = following(track: 13)
        m.step(1, cueTimes: cues, host: 0)                 // in cue 12 → next is 20
        XCTAssertEqual(m.state, .manual(index: 2))
        XCTAssertEqual(m.playhead(at: 3), 20)
        m.step(1, cueTimes: cues, host: 0)                 // clamps at the last cue
        XCTAssertEqual(m.state, .manual(index: 2))
        m.step(-1, cueTimes: cues, host: 0); m.step(-1, cueTimes: cues, host: 0); m.step(-1, cueTimes: cues, host: 0)
        XCTAssertEqual(m.state, .manual(index: -1))
        XCTAssertEqual(m.playhead(at: 0), 0)
        m.ltc(trackTime: 50, host: 1)                      // LTC arriving doesn't take over
        XCTAssertEqual(m.state, .manual(index: -1))
        XCTAssertTrue(m.ltcPresent)
        m.resumeFollowing(host: 1.05)
        XCTAssertEqual(m.state, .following)
        XCTAssertEqual(m.playhead(at: 1.05), 50.05, accuracy: 1e-9)
    }

    func testResumeWithoutTimecodeIsLost() {
        var m = following()
        m.step(1, cueTimes: [11], host: 0)
        m.tick(host: 3)
        m.resumeFollowing(host: 3)
        XCTAssertEqual(m.state, .lost)
    }

    func testStepFromLost() {
        var m = following()
        m.tick(host: 5)                                     // lost, held at 11.1
        m.step(1, cueTimes: [5, 11, 15], host: 5)
        XCTAssertEqual(m.state, .manual(index: 2))
    }

    func testNudge() {
        var m = following()
        m.nudge(by: 1.0 / 30); m.nudge(by: 1.0 / 30)
        XCTAssertEqual(m.playhead(at: 0), 10 + 2.0 / 30, accuracy: 1e-9)
        m.step(1, cueTimes: [12], host: 0)
        XCTAssertEqual(m.playhead(at: 0), 12 + 2.0 / 30, accuracy: 1e-9)
        m.resetNudge()
        XCTAssertEqual(m.nudge, 0)
    }
}
