import XCTest
@testable import TCPlayback

final class EngineRingBufferTests: XCTestCase {
    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(SPSCRingBuffer(channels: 2, minimumCapacity: 1000).capacity, 1024)
        XCTAssertEqual(SPSCRingBuffer(channels: 1, minimumCapacity: 1024).capacity, 1024)
    }

    func testWriteReadAndFull() {
        let ring = SPSCRingBuffer(channels: 2, minimumCapacity: 8)
        var l: [Float] = (0..<10).map(Float.init)
        var r: [Float] = (0..<10).map { Float($0) * -1 }
        let wrote = ring.write(&l, &r, count: 10)
        XCTAssertEqual(wrote, 8, "write must stop at capacity")
        XCTAssertEqual(ring.writableCount, 0)
        XCTAssertEqual(ring.readableCount, 8)
        var ol = [Float](repeating: 99, count: 8), or = [Float](repeating: 99, count: 8)
        XCTAssertEqual(ring.read(&ol, &or, count: 8), 8)
        XCTAssertEqual(ol, Array(l[0..<8]))
        XCTAssertEqual(or, Array(r[0..<8]))
        XCTAssertEqual(ring.read(&ol, &or, count: 8), 0)
    }

    func testWraparound() {
        let ring = SPSCRingBuffer(channels: 2, minimumCapacity: 8)
        var next: Float = 0
        var expected: Float = 0
        // Many odd-sized cycles so writes and reads straddle the end of storage.
        for cycle in 0..<200 {
            let n = 1 + (cycle * 5) % 8
            var l = (0..<n).map { _ -> Float in defer { next += 1 }; return next }
            var r = l.map { -$0 }
            XCTAssertEqual(ring.write(&l, &r, count: n), n)
            var ol = [Float](repeating: 0, count: n), or = [Float](repeating: 0, count: n)
            XCTAssertEqual(ring.read(&ol, &or, count: n), n)
            for i in 0..<n {
                XCTAssertEqual(ol[i], expected)
                XCTAssertEqual(or[i], -expected)
                expected += 1
            }
        }
        XCTAssertEqual(ring.totalRead, ring.totalWritten)
    }

    func testNilSourceWritesSilenceAndPeekDoesNotConsume() {
        let ring = SPSCRingBuffer(channels: 2, minimumCapacity: 16)
        var l: [Float] = [1, 2, 3, 4]
        ring.write(&l, nil, count: 4)
        var pl = [Float](repeating: 9, count: 4), pr = [Float](repeating: 9, count: 4)
        XCTAssertEqual(ring.peek(&pl, &pr, count: 4), 4)
        XCTAssertEqual(pl, [1, 2, 3, 4])
        XCTAssertEqual(pr, [0, 0, 0, 0])
        XCTAssertEqual(ring.readableCount, 4)
        ring.producerDiscardUnread()
        XCTAssertEqual(ring.readableCount, 0)
    }

    func testConcurrentProducerConsumer() {
        let ring = SPSCRingBuffer(channels: 2, minimumCapacity: 1024)
        let total = 2_000_000
        let producerDone = expectation(description: "producer")
        DispatchQueue.global(qos: .userInitiated).async {
            var sent = 0
            var l = [Float](repeating: 0, count: 777), r = [Float](repeating: 0, count: 777)
            var size = 1
            while sent < total {
                let n = min(size, 777, total - sent)
                for i in 0..<n { l[i] = Float(sent + i); r[i] = -Float(sent + i) }
                var off = 0
                while off < n {
                    let w = l.withUnsafeBufferPointer { lb in r.withUnsafeBufferPointer { rb in
                        ring.write(lb.baseAddress! + off, rb.baseAddress! + off, count: n - off)
                    } }
                    off += w
                    if w == 0 { usleep(10) }
                }
                sent += n
                size = size % 777 + 13
            }
            producerDone.fulfill()
        }
        var received = 0
        var errors = 0
        var ol = [Float](repeating: 0, count: 500), or = [Float](repeating: 0, count: 500)
        var chunk = 1
        let deadline = Date().addingTimeInterval(30)
        while received < total && Date() < deadline {
            let n = ring.read(&ol, &or, count: min(chunk, 500))
            for i in 0..<n where ol[i] != Float(received + i) || or[i] != -Float(received + i) { errors += 1 }
            received += n
            chunk = chunk % 500 + 7
            if n == 0 { usleep(5) }
        }
        wait(for: [producerDone], timeout: 30)
        XCTAssertEqual(received, total)
        XCTAssertEqual(errors, 0, "samples must arrive intact and in order")
    }
}
