import XCTest
@testable import TCKit
final class TimecodeTests: XCTestCase { func testRoundTrip() { for r in FrameRate.allCases { for n in stride(from: 0, to: 200000, by: 37) { XCTAssertEqual(Timecode(frameNumber: n, rate: r).frameNumber, n, "\(r) \(n)") } } } }
