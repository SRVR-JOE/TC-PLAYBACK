import XCTest
@testable import TCKit

final class TimecodeTests: XCTestCase {
    func testRoundTrip() {
        for r in FrameRate.allCases {
            for n in stride(from: 0, to: 200000, by: 37) {
                XCTAssertEqual(Timecode(frameNumber: n, rate: r).frameNumber, n, "\(r) \(n)")
            }
        }
    }

    func testDropFrameEdges() {
        let df = FrameRate.fps29_97df
        XCTAssertEqual(Timecode(string: "00:00:59;29", rate: df)!.adding(frames: 1).description, "00:01:00;02")
        XCTAssertEqual(Timecode(string: "00:09:59;29", rate: df)!.adding(frames: 1).description, "00:10:00;00")
        XCTAssertEqual(Timecode(string: "00:01:00;02", rate: df)!.adding(frames: -1).description, "00:00:59;29")
        XCTAssertEqual(Timecode(string: "23:59:59;29", rate: df)!.adding(frames: 1).description, "00:00:00;00")
        XCTAssertEqual(Timecode(string: "00:00:00;00", rate: df)!.adding(frames: -1).description, "23:59:59;29")
        // 10 minutes of DF = 17982 frames; an hour = 107892.
        XCTAssertEqual(Timecode(string: "00:10:00;00", rate: df)!.frameNumber, 17982)
        XCTAssertEqual(Timecode(string: "01:00:00;00", rate: df)!.frameNumber, 107_892)
        // DF keeps real time: one hour of DF timecode ≈ one hour of wall clock (within 3.6 ms).
        XCTAssertEqual(Timecode(string: "01:00:00;00", rate: df)!.realSeconds, 3600, accuracy: 0.004)
        // Every frame number in a day maps to a valid label and back.
        let perDay = 24 * 107_892
        for n in stride(from: 0, to: perDay, by: 7) {
            let tc = Timecode(frameNumber: n, rate: df)
            XCTAssertFalse(tc.seconds == 0 && tc.frames < 2 && tc.minutes % 10 != 0, "\(tc)")
            XCTAssertEqual(tc.frameNumber, n)
        }
        XCTAssertEqual(Timecode(frameNumber: perDay, rate: df).frameNumber, 0)
    }

    func testNonDropWrap() {
        XCTAssertEqual(Timecode(string: "23:59:59:24", rate: .fps25)!.adding(frames: 1), .zero(.fps25))
        XCTAssertEqual(Timecode(frameNumber: -1, rate: .fps24).description, "23:59:59:23")
        XCTAssertEqual(Timecode(string: "00:00:59:29", rate: .fps29_97ndf)!.adding(frames: 1).description, "00:01:00:00")
    }

    func testParsing() {
        XCTAssertEqual(Timecode(string: "01:02:03:04", rate: .fps25), Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps25))
        XCTAssertEqual(Timecode(string: "01:02:03;04", rate: .fps29_97df)?.description, "01:02:03;04")
        XCTAssertEqual(Timecode(string: "01020304", rate: .fps30)?.description, "01:02:03:04")
        XCTAssertEqual(Timecode(string: " 10:00:00:00 ", rate: .fps24)?.hours, 10)
        XCTAssertNil(Timecode(string: "01:02:03:25", rate: .fps25))   // frame out of range
        XCTAssertNil(Timecode(string: "01:02:03:24", rate: .fps24))
        XCTAssertNotNil(Timecode(string: "01:02:03:24", rate: .fps25))
        XCTAssertNil(Timecode(string: "24:00:00:00", rate: .fps25))
        XCTAssertNil(Timecode(string: "00:60:00:00", rate: .fps25))
        XCTAssertNil(Timecode(string: "00:00:60:00", rate: .fps25))
        XCTAssertNil(Timecode(string: "00:01:00;00", rate: .fps29_97df)) // dropped label
        XCTAssertNil(Timecode(string: "00:01:00;01", rate: .fps29_97df))
        XCTAssertNotNil(Timecode(string: "00:10:00;00", rate: .fps29_97df))
        XCTAssertNotNil(Timecode(string: "00:01:00:00", rate: .fps29_97ndf))
        XCTAssertNil(Timecode(string: "1:2:3:4", rate: .fps25))
        XCTAssertNil(Timecode(string: "", rate: .fps25))
        XCTAssertNil(Timecode(string: "01:02:03:045", rate: .fps25))
        XCTAssertNil(Timecode(string: "ab:cd:ef:gh", rate: .fps25))
        // Non-ASCII numerics used to crash the parser.
        XCTAssertNil(Timecode(string: "01:02:03:0²", rate: .fps25))
        XCTAssertNil(Timecode(string: "０１:02:03:04", rate: .fps25))
        XCTAssertNil(Timecode(string: "01:02:03:0½", rate: .fps25))
    }

    func testRealSecondsRoundTrip() {
        for r in FrameRate.allCases {
            for n in 0..<50_000 {
                let tc = Timecode(frameNumber: n, rate: r)
                XCTAssertEqual(Timecode(realSeconds: tc.realSeconds, rate: r), tc, "\(r) \(n)")
            }
            XCTAssertEqual(Timecode(realSeconds: .nan, rate: r), .zero(r))
            XCTAssertEqual(Timecode(realSeconds: -5, rate: r), .zero(r))
        }
        let tc = Timecode(string: "01:00:00:00", rate: .fps25)!
        XCTAssertEqual(tc.adding(seconds: 0), tc)
        XCTAssertEqual(tc.adding(seconds: 1).description, "01:00:01:00")
    }
}
