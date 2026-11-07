import AVFoundation
import XCTest
@testable import TCPlayback

final class ToolsCueCallerEngineTests: XCTestCase {
    private let lights = UUID()
    private func settings(_ areas: [CueCallArea], standby: Bool = true, lead: Double = 5) -> CueCallerSettings {
        var s = CueCallerSettings()
        s.enabled = true; s.sayStandby = standby; s.standbyLead = lead; s.areas = areas
        return s
    }

    // MARK: Scheduler

    func testSchedulerBuildsStandbyAndGoPerArea() async {
        let en = CueCallArea(name: "Cameras", language: "en-US")
        let es = CueCallArea(name: "Cámaras", language: "es-MX", outputChannels: [2])
        let m = CueCallMark(time: 10, name: "Drop", note: "Camera 3, push in slow")
        let calls = await CueCallScheduler.build(marks: [m], settings: settings([en, es]), noteLanguage: "en-US",
                                                 translator: UpperTranslator())
        XCTAssertEqual(calls.count, 4)
        let enGo = calls.first { $0.areaID == en.id && $0.kind == .go }
        let enSb = calls.first { $0.areaID == en.id && $0.kind == .standby }
        let esGo = calls.first { $0.areaID == es.id && $0.kind == .go }
        XCTAssertEqual(enGo?.text, "Camera 3, push in slow… go.")
        XCTAssertEqual(enGo?.at, 10)
        XCTAssertEqual(enSb?.text, "Standby, Camera 3, push in slow.")
        XCTAssertEqual(enSb?.at, 5)
        XCTAssertEqual(esGo?.text, "[es-MX] CAMERA 3, PUSH IN SLOW… ya.", "note translated, Spanish go word")
    }

    func testNotesAndMarkNames() {
        let a = CueCallArea(name: "A", language: "en-US")
        let marks = [CueCallMark(time: 1, name: "Chorus 1", note: ""), CueCallMark(time: 2, name: "X", note: "Lights")]
        var s = settings([a], standby: false)
        XCTAssertEqual(CueCallScheduler.requests(marks: marks, settings: s).map(\.text), ["Lights"], "only marks with notes")
        s.onlyMarksWithNotes = false
        XCTAssertEqual(CueCallScheduler.requests(marks: marks, settings: s).map(\.text), ["", "Lights"])
        s.includeMarkName = true
        XCTAssertEqual(CueCallScheduler.requests(marks: marks, settings: s).map(\.text), ["Chorus 1", "Lights"])
        XCTAssertEqual(CueCallScheduler.compose(.go, text: "", word: "go"), "Go.")
        XCTAssertEqual(CueCallScheduler.compose(.go, text: "Chorus 1", word: "go"), "Chorus 1… go.")
    }

    func testLaneFilterAndDisabledArea() {
        var cams = CueCallArea(name: "Cams", language: "en-US"); cams.laneIDs = [CuePointType.defaultID]
        var lx = CueCallArea(name: "LX", language: "en-US"); lx.laneIDs = [lights]
        var off = CueCallArea(name: "Off", language: "en-US"); off.enabled = false
        let marks = [CueCallMark(time: 1, note: "cam"), CueCallMark(time: 2, note: "lx", typeID: lights)]
        let r = CueCallScheduler.requests(marks: marks, settings: settings([cams, lx, off], standby: false))
        XCTAssertEqual(r.filter { $0.areaID == cams.id }.map(\.text), ["cam"])
        XCTAssertEqual(r.filter { $0.areaID == lx.id }.map(\.text), ["lx"])
        XCTAssertTrue(r.filter { $0.areaID == off.id }.isEmpty)
        var all = CueCallArea(name: "All", language: "en-US"); all.laneIDs = []
        XCTAssertEqual(CueCallScheduler.requests(marks: marks, settings: settings([all], standby: false)).count, 2)
    }

    // MARK: Timing

    func testGoEndsOnTheMark() {
        let area = UUID()
        let go = CueCall(markID: UUID(), areaID: area, kind: .go, at: 20, text: "x")
        let sb = CueCall(markID: go.markID, areaID: area, kind: .standby, at: 15, text: "y")
        XCTAssertEqual(CueCallScheduler.startTime(go, duration: 1.8), 18.2, accuracy: 1e-9)
        XCTAssertEqual(CueCallScheduler.startTime(sb, duration: 1.8), 15)
        let t = CueCallScheduler.timeline([go, sb]) { _ in (1.8, false) }
        let g = t.first { $0.call.kind == .go }!
        XCTAssertEqual(g.start + g.duration, 20, accuracy: 1e-9)
        XCTAssertNil(g.cutAt)
    }

    func testOverlapLaterCallWinsInSameAreaOnly() {
        let a = UUID(), b = UUID()
        let first = CueCall(markID: UUID(), areaID: a, kind: .go, at: 10, text: "first")
        let second = CueCall(markID: UUID(), areaID: a, kind: .go, at: 10.5, text: "second")
        let other = CueCall(markID: UUID(), areaID: b, kind: .go, at: 10.5, text: "other area")
        let t = CueCallScheduler.timeline([first, second, other]) { _ in (2, false) }
        let f = t.first { $0.call == first }!, s = t.first { $0.call == second }!, o = t.first { $0.call == other }!
        XCTAssertEqual(f.start, 8); XCTAssertEqual(s.start, 8.5)
        XCTAssertEqual(f.cutAt, 8.5, "earlier call fades where the later one starts")
        XCTAssertNil(s.cutAt)
        XCTAssertNil(o.cutAt, "other areas talk independently")
    }

    func testGoOnsetPutsGoWordOnTheMark() {
        let area = UUID()
        let go = CueCall(markID: UUID(), areaID: area, kind: .go, at: 20, text: "Camera 3… go.")
        let sb = CueCall(markID: go.markID, areaID: area, kind: .standby, at: 15, text: "Standby.")
        // Audio 2.0 s, go word starts 1.6 s in: the voice starts at 18.4 and runs past the mark.
        let t = CueCallScheduler.timeline([go, sb], timing: { _ in CueCallTiming(duration: 2.0, goOnset: 1.6) })
        let g = t.first { $0.call.kind == .go }!, s = t.first { $0.call.kind == .standby }!
        XCTAssertEqual(g.start, 18.4, accuracy: 1e-9)
        XCTAssertEqual(g.start + g.goOnset!, 20, accuracy: 1e-9)
        XCTAssertEqual(s.start, 15, "standby ignores the onset")
        XCTAssertNil(s.goOnset)
        // No onset: the end lands on the mark; an onset past the end is clamped.
        XCTAssertEqual(CueCallScheduler.startTime(go, duration: 2, goOnset: nil), 18)
        let c = CueCallScheduler.timeline([go], timing: { _ in CueCallTiming(duration: 2.0, goOnset: 9) })
        XCTAssertEqual(c[0].start, 18, accuracy: 1e-9)
    }

    func testInjectedPhraseGetsTranslatedNoteOnly() async {
        let es = CueCallArea(name: "Cámaras", language: "es-MX")
        let m = CueCallMark(time: 10, note: "Camera 3")
        let phrase: CueCallPhrase = { kind, note, lang in "<\(kind.rawValue)|\(note)|\(lang)>" }
        let p = await CueCallScheduler.prepare(marks: [m], settings: settings([es]), noteLanguage: "en-US",
                                               translator: UpperTranslator(), phrase: phrase)
        XCTAssertEqual(p.map(\.call.text), ["<standby|[es-MX] CAMERA 3|es-MX>", "<go|[es-MX] CAMERA 3|es-MX>"])
        XCTAssertEqual(p.map(\.note), ["[es-MX] CAMERA 3", "[es-MX] CAMERA 3"])
    }

    func testStubRenderStepReportsOnsetAtEnd() async throws {
        let step = StubCueCallRenderer().renderStep()
        let area = CueCallArea(name: "A", language: "en-US")
        let go = CueCall(markID: UUID(), areaID: area.id, kind: .go, at: 1, text: "Go.")
        let a = try await step(go, "", area, 48_000)
        XCTAssertEqual(a.goOnset, a.samples.count)
        let sb = CueCall(markID: go.markID, areaID: area.id, kind: .standby, at: 0, text: "Standby.")
        let b = try await step(sb, "", area, 48_000)
        XCTAssertNil(b.goOnset)
    }

    // MARK: Follower

    private func calls(_ starts: [Double]) -> [TimedCueCall] {
        starts.map { TimedCueCall(call: CueCall(markID: UUID(), areaID: UUID(), kind: .go, at: $0 + 1, text: "c"), start: $0, duration: 1) }
    }

    private func armed(_ a: [CueCallFollower.Action]) -> [Double] {
        a.compactMap { if case .arm(let c) = $0 { return c.start } else { return nil } }
    }

    func testFollowerArmsAheadOnce() {
        var f = CueCallFollower()
        let c = calls([5, 10])
        XCTAssertEqual(armed(f.update(time: 4.0, elapsed: 0, calls: c)), [])
        XCTAssertEqual(armed(f.update(time: 4.6, elapsed: 0.6, calls: c)), [5])
        XCTAssertEqual(armed(f.update(time: 4.62, elapsed: 0.02, calls: c)), [], "armed once")
        var t = 4.62, all: [Double] = []
        while t < 11 { t += 0.02; all += armed(f.update(time: t, elapsed: 0.02, calls: c)) }
        XCTAssertEqual(all, [10])
    }

    func testSeekForwardDoesNotBacklog() {
        var f = CueCallFollower()
        let c = calls([5, 8, 12, 20])
        _ = f.update(time: 1, elapsed: 0, calls: c)
        let a = f.update(time: 15, elapsed: 0.02, calls: c) // seek
        XCTAssertTrue(a.contains(.cancelAll))
        XCTAssertEqual(armed(a), [], "nothing behind the new position fires")
        var t = 15.0, all: [Double] = []
        while t < 21 { t += 0.02; all += armed(f.update(time: t, elapsed: 0.02, calls: c)) }
        XCTAssertEqual(all, [20])
    }

    func testRewindRearmsEarlierCalls() {
        var f = CueCallFollower()
        let c = calls([5])
        var t = 4.0
        _ = f.update(time: t, elapsed: 0, calls: c)
        var fired = 0
        while t < 6 { t += 0.02; fired += armed(f.update(time: t, elapsed: 0.02, calls: c)).count }
        XCTAssertEqual(fired, 1)
        _ = f.update(time: 2, elapsed: 0.02, calls: c) // rewind
        t = 2
        while t < 6 { t += 0.02; fired += armed(f.update(time: t, elapsed: 0.02, calls: c)).count }
        XCTAssertEqual(fired, 2)
    }

    func testTimecodeLossStopsAndResumeDoesNotBurst() {
        var f = CueCallFollower()
        let c = calls([5, 6, 7, 12])
        var t = 3.0
        _ = f.update(time: t, elapsed: 0, calls: c)
        XCTAssertEqual(f.update(time: nil, elapsed: 0.02, calls: c), [.cancelAll], "loss stops calling")
        XCTAssertEqual(f.update(time: nil, elapsed: 0.02, calls: c), [], "only once")
        // TC returns 5 s later, past three calls.
        t = 8.0
        XCTAssertEqual(armed(f.update(time: t, elapsed: 5, calls: c)), [], "no burst on resume")
        var all: [Double] = []
        while t < 13 { t += 0.02; all += armed(f.update(time: t, elapsed: 0.02, calls: c)) }
        XCTAssertEqual(all, [12])
    }

    func testLateCallWithinToleranceStillFiresBeyondIsSkipped() {
        var f = CueCallFollower()
        f.lookahead = 0
        let c = calls([5])
        _ = f.update(time: 4.9, elapsed: 0, calls: c)
        XCTAssertEqual(armed(f.update(time: 5.05, elapsed: 0.15, calls: c)), [5])
        var g = CueCallFollower(); g.lookahead = 0
        _ = g.update(time: 4.9, elapsed: 0, calls: c)
        XCTAssertEqual(armed(g.update(time: 5.3, elapsed: 0.4, calls: c)), [], "too late: skipped, not bunched")
        XCTAssertEqual(g.skipped.count, 1)
    }

    func testTimecodeClockSmoothsAndReanchorsOnJump() {
        var k = CueCallTimecodeClock()
        let frame = 1.0 / 30
        var est = 0.0
        for i in 0..<60 { // 2 s of readings at 30 Hz, each floored to a frame
            let host = Double(i) / 30 + 0.013
            let reading = (host * 30).rounded(.down) / 30
            est = k.update(reading: 10 + reading, frame: frame, host: host)
        }
        XCTAssertEqual(est, 10 + 59.0 / 30 + 0.013, accuracy: 0.02)
        XCTAssertEqual(k.update(reading: 40, frame: frame, host: 2.01), 40 + frame / 2, accuracy: 1e-9, "jump re-anchors")
    }

    // MARK: Mixer (render path)

    func testMixerStartsOnTrackFrameOnItsChannelsAndFades() {
        let mixer = CueCallMixer(sampleRate: 48_000)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
        buf.frameLength = 512
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        XCTAssertTrue(mixer.play([Float](repeating: 0.5, count: 1500), clock: .track, startFrame: 1000, channels: [2],
                                 gain: 1, tag: 7))
        var out: [[Float]] = Array(repeating: [], count: 4)
        var track = 0
        for _ in 0..<6 {
            for c in 0..<4 { buf.floatChannelData![c].update(repeating: 0, count: 512) }
            mixer.mix(abl, frames: 512, trackStart: track, trackRunning: true)
            for c in 0..<4 { out[c] += Array(UnsafeBufferPointer(start: buf.floatChannelData![c], count: 512)) }
            track += 512
        }
        XCTAssertEqual(out[2].firstIndex { $0 != 0 }, 1000, "starts on the scheduled frame")
        XCTAssertEqual(out[2].lastIndex { $0 != 0 }, 2499)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 } && out[1].allSatisfy { $0 == 0 } && out[3].allSatisfy { $0 == 0 },
                      "only on the area's channel")
        let reports = mixer.drainReports()
        XCTAssertEqual(reports.last?.startedAt, 1000)
        XCTAssertEqual(reports.last?.endedAt, 2500)

        // Overlap cut: fade from frame 3200, 30 ms (1440 frames) later it's silent.
        mixer.reclaim()
        XCTAssertTrue(mixer.play([Float](repeating: 0.5, count: 4800), clock: .track, startFrame: 3072, channels: [0],
                                 gain: 1, fadeAt: 3200, tag: 8))
        var ch0: [Float] = []
        for _ in 0..<8 {
            for c in 0..<4 { buf.floatChannelData![c].update(repeating: 0, count: 512) }
            mixer.mix(abl, frames: 512, trackStart: track, trackRunning: true)
            ch0 += Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: 512))
            track += 512
        }
        let first = ch0.firstIndex { $0 != 0 }!
        let last = ch0.lastIndex { $0 != 0 }!
        XCTAssertEqual(first + 3072, 3072)
        XCTAssertEqual(Double(last + 3072 - 3200), 1440, accuracy: 2)
        XCTAssertTrue(mixer.drainReports().last?.wasFaded ?? false)
    }

    func testMixerWaitsWhileTrackIsStoppedAndCancelDropsArmedVoice() {
        let mixer = CueCallMixer(sampleRate: 48_000)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 256)!
        buf.frameLength = 256
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        mixer.play([Float](repeating: 1, count: 100), clock: .track, startFrame: 0, channels: [0], gain: 1, tag: 1)
        mixer.mix(abl, frames: 256, trackStart: 0, trackRunning: false)
        XCTAssertTrue(UnsafeBufferPointer(start: buf.floatChannelData![0], count: 256).allSatisfy { $0 == 0 })
        mixer.fadeAll()
        mixer.mix(abl, frames: 256, trackStart: 0, trackRunning: true)
        XCTAssertTrue(UnsafeBufferPointer(start: buf.floatChannelData![0], count: 256).allSatisfy { $0 == 0 })
        XCTAssertEqual(mixer.activeCount, 0)
    }

    func testStubRendererLengthFollowsText() async throws {
        let r = StubCueCallRenderer()
        let short = try await r.render("Go", language: "en-US", voiceID: nil, rate: 0.5, sampleRate: 48_000)
        let long = try await r.render("Camera 3, push in slow… go.", language: "en-US", voiceID: nil, rate: 0.5, sampleRate: 48_000)
        XCTAssertGreaterThan(long.count, short.count)
    }
}

private struct UpperTranslator: CueCallTranslator {
    func translate(_ text: String, from: String, to: String) async throws -> String { "[\(to)] " + text.uppercased() }
}
