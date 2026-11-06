import XCTest
import TCKit
@testable import TCPlayback

final class ToolsPadsTests: XCTestCase {
    // MARK: Keypad entry

    private func type(_ s: String, into e: inout TCEntry) {
        for ch in s { if let d = ch.wholeNumberValue { e.push(d) } }
    }

    func testEntryFillsFromTheRight() {
        var e = TCEntry()
        type("1", into: &e)
        XCTAssertEqual(e.display(rate: .fps25), "00:00:00:01")
        type("000000", into: &e)
        XCTAssertEqual(e.display(rate: .fps25), "01:00:00:00")
        XCTAssertEqual(e.timecode(rate: .fps25), Timecode(hours: 1, rate: .fps25))
        XCTAssertEqual(e.typedCount, 7)
    }

    func testEntryFreshReplacesThenBackspaceAndDoubleZero() {
        var e = TCEntry(timecode: Timecode(hours: 10, minutes: 20, seconds: 30, frames: 4, rate: .fps30))
        e.push(5)                                   // first digit replaces the shown value
        XCTAssertEqual(e.display(rate: .fps30), "00:00:00:05")
        e.pushDoubleZero()
        XCTAssertEqual(e.display(rate: .fps30), "00:00:05:00")
        e.backspace()
        XCTAssertEqual(e.display(rate: .fps30), "00:00:00:50")
        e.clear()
        XCTAssertEqual(e.display(rate: .fps30), "00:00:00:00")
        // Overflow keeps the eight most recent digits.
        type("123456789", into: &e)
        XCTAssertEqual(e.display(rate: .fps30), "23:45:67:89")
        XCTAssertNotNil(e.validationMessage(rate: .fps30))
    }

    func testEntryValidatesPerRate() {
        var f = TCEntry(); type("01000025", into: &f)
        XCTAssertNotNil(f.validationMessage(rate: .fps25))   // frame 25 doesn't exist at 25
        XCTAssertNil(f.validationMessage(rate: .fps30))
        var g = TCEntry(); type("01000024", into: &g)
        XCTAssertNil(g.validationMessage(rate: .fps25))
        XCTAssertNotNil(g.validationMessage(rate: .fps24))
        XCTAssertNotNil(g.validationMessage(rate: .fps23_976))
        var g2 = TCEntry(); type("01000023", into: &g2)
        XCTAssertNil(g2.validationMessage(rate: .fps23_976))
        var h = TCEntry(); type("24000000", into: &h)
        XCTAssertNotNil(h.validationMessage(rate: .fps30))
        var m = TCEntry(); type("00600000", into: &m)
        XCTAssertNotNil(m.validationMessage(rate: .fps30))
        XCTAssertNil(m.timecode(rate: .fps30))
    }

    func testEntryDropFrameValidation() {
        // 00:01:00;00 and ;01 don't exist in DF; ;02 does; every tenth minute keeps 00/01.
        for (digits, valid) in [("00010000", false), ("00010001", false), ("00010002", true),
                                ("00100000", true), ("00100001", true), ("01000000", true),
                                ("00011000", true), ("00090001", false)] {
            var e = TCEntry(); type(digits, into: &e)
            XCTAssertEqual(e.validationMessage(rate: .fps29_97df) == nil, valid, digits)
            XCTAssertNil(e.validationMessage(rate: .fps29_97ndf), digits)
        }
        var e = TCEntry(); type("00010002", into: &e)
        XCTAssertEqual(e.display(rate: .fps29_97df), "00:01:00;02")
    }

    // MARK: Nudge maths

    func testNudges() {
        let tc = Timecode(hours: 1, rate: .fps25)
        XCTAssertEqual(PadMath.nudge(tc, by: .plus1f).description, "01:00:00:01")
        XCTAssertEqual(PadMath.nudge(tc, by: .minus1f).description, "00:59:59:24")
        XCTAssertEqual(PadMath.nudge(tc, by: .plus1s).description, "01:00:01:00")
        XCTAssertEqual(PadMath.nudge(tc, by: .minus1s).description, "00:59:59:00")
        XCTAssertEqual(PadMath.nudge(tc, by: .plus10s).description, "01:00:10:00")
        XCTAssertEqual(PadMath.nudge(tc, by: .minus10s).description, "00:59:50:00")
        // Wraps through midnight.
        XCTAssertEqual(PadMath.nudge(Timecode.zero(.fps30), by: .minus1f).description, "23:59:59:29")
        XCTAssertEqual(PadMath.nudge(Timecode(hours: 23, minutes: 59, seconds: 59, frames: 29, rate: .fps30), by: .plus1f).description,
                       "00:00:00:00")
    }

    func testDropFrameNudges() {
        let top = Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps29_97df)
        XCTAssertEqual(PadMath.nudge(top, by: .minus1f).description, "00:00:59;29")
        XCTAssertEqual(PadMath.nudge(Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29, rate: .fps29_97df), by: .plus1f).description,
                       "00:01:00;02")
        // +1 s is 30 counted frames, so the seconds digit moves by one.
        XCTAssertEqual(PadMath.nudge(Timecode(hours: 1, minutes: 0, seconds: 10, frames: 0, rate: .fps29_97df), by: .plus1s).description,
                       "01:00:11;00")
    }

    func testPreRollAndRemainingDuration() {
        let cue = Timecode(hours: 1, rate: .fps25)
        XCTAssertEqual(PadMath.generatorStart(cue: cue, preRoll: 5).description, "00:59:55:00")
        XCTAssertEqual(PadMath.generatorStart(cue: cue, preRoll: 0), cue)
        let start = PadMath.generatorStart(cue: cue, preRoll: 5)
        XCTAssertEqual(PadMath.remainingDuration(from: start, cue: cue, duration: 10)!, 15, accuracy: 0.001)
        XCTAssertNil(PadMath.remainingDuration(from: start, cue: cue, duration: nil))
        XCTAssertEqual(PadMath.remainingDuration(from: cue.adding(frames: 300), cue: cue, duration: 10), 0)
        let late = Timecode(hours: 23, minutes: 59, seconds: 58, frames: 0, rate: .fps25)
        XCTAssertEqual(PadMath.remainingDuration(from: late, cue: late, duration: 4)!, 4, accuracy: 0.001)
    }

    func testConformClampsToRate() {
        let tc = Timecode(hours: 1, minutes: 1, seconds: 0, frames: 29, rate: .fps30)
        XCTAssertEqual(TCPad.conform(tc, to: .fps25).frames, 24)
        let df = TCPad.conform(Timecode(hours: 0, minutes: 1, seconds: 0, frames: 0, rate: .fps30), to: .fps29_97df)
        XCTAssertEqual(df.description, "00:01:00;02")
    }

    // MARK: Persistence

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pads-\(UUID().uuidString)/banks.json")
    }

    func testBankJSONRoundTrip() throws {
        var lib = PadLibrary.makeDefault()
        lib.banks[0].rate = .fps29_97df
        lib.banks[0].preRollSeconds = 5
        lib.banks[1].pads = [TCPad(label: "Walk-in", start: Timecode(hours: 0, minutes: 59, seconds: 30, rate: .fps25),
                                   rateOverride: .fps25, side: .left, levelDBFS: -14, duration: 90, color: .blue,
                                   preRollOverride: 2)]
        lib.selectedBankID = lib.banks[1].id
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PadStore(url: url)
        try store.save(lib)
        let back = try XCTUnwrap(store.load())
        XCTAssertEqual(back, lib)
        XCTAssertEqual(back.banks[1].pads[0].startTimecode(in: back.banks[1]).description, "00:59:30:00")
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"Walk-in\""))
    }

    func testHourQuickFillAndControllerEditing() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c = PadController(store: PadStore(url: url), engine: PlaybackEngine())
        c.quickFillHours(.replace)
        XCTAssertEqual(c.bank.pads.map { $0.start.hours }, Array(1...10))
        XCTAssertEqual(c.bank.pads.last?.startTimecode(in: c.bank).description, "10:00:00:00")
        let first = c.bank.pads[0].id, third = c.bank.pads[2].id
        c.duplicate(first)
        XCTAssertEqual(c.bank.pads.count, 11)
        c.move(first, onto: third)
        XCTAssertEqual(c.bank.pads[3].id, first)
        c.delete(first)
        XCTAssertEqual(c.bank.pads.count, 10)
        c.addBank()
        XCTAssertEqual(c.bank.name, "D")
        let reloaded = PadController(store: PadStore(url: url), engine: PlaybackEngine())
        XCTAssertEqual(reloaded.library, c.library)
    }

    func testFireAndNudgeDriveTheGenerator() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlaybackEngine()
        let c = PadController(store: PadStore(url: url), engine: engine)
        c.updateBank { $0.rate = .fps25; $0.preRollSeconds = 5 }
        let pad = c.bank.pads[0]
        c.fire(pad)
        guard case .generator(let cfg) = engine.source else { return XCTFail("generator not loaded") }
        XCTAssertEqual(cfg.start.description, "00:59:55:00")
        XCTAssertEqual(cfg.rate, .fps25)
        XCTAssertEqual(engine.transport, .playing)
        XCTAssertEqual(c.activePadID, pad.id)
        c.togglePause()
        XCTAssertEqual(engine.transport, .paused)
        c.nudge(.plus10s)
        guard case .generator(let cfg2) = engine.source else { return XCTFail("generator not reloaded") }
        XCTAssertEqual(cfg2.start.description, "01:00:05:00")
        XCTAssertEqual(engine.transport, .paused)      // relocating while paused stays paused
        c.stop()
        XCTAssertEqual(engine.transport, .stopped)
        XCTAssertNil(c.activePadID)
    }
}
