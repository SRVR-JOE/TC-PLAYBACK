import XCTest
@testable import TCPlayback
final class SmokeTests: XCTestCase { func testRouting() { XCTAssertTrue(ChannelRouting().leftEnabled) } }
