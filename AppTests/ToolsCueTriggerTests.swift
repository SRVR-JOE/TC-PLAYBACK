import XCTest
@testable import TCPlayback

final class ToolsCueTriggerTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private var marks: [CueTriggerClock.Mark] { [.init(id: a, time: 10, colorHex: nil), .init(id: b, time: 10.5, colorHex: nil)] }

    func testFiresOnTheFrameThatReachesTheMark() {
        XCTAssertNil(CueTriggerClock.crossed(marks, from: 9.98, to: 9.995))
        XCTAssertEqual(CueTriggerClock.crossed(marks, from: 9.995, to: 10.003)?.id, a)
        XCTAssertNil(CueTriggerClock.crossed(marks, from: 10.003, to: 10.011), "fires once")
        XCTAssertEqual(CueTriggerClock.crossed(marks, from: 9.99, to: 10.0)?.id, a, "exactly on the mark counts")
    }

    func testSeeksAndRewindsDoNotFire() {
        XCTAssertNil(CueTriggerClock.crossed(marks, from: 2, to: 30), "jump forward")
        XCTAssertNil(CueTriggerClock.crossed(marks, from: 10.2, to: 9.9), "backwards")
    }

    func testTwoMarksInOneFrameFireTheLater() {
        let close: [CueTriggerClock.Mark] = [.init(id: a, time: 10, colorHex: nil), .init(id: b, time: 10.004, colorHex: nil)]
        XCTAssertEqual(CueTriggerClock.crossed(close, from: 9.999, to: 10.008)?.id, b)
    }
}
