import XCTest
@testable import TCPlayback

final class EngineRoutingTests: XCTestCase {
    func testDefaultIsIdentity() {
        XCTAssertEqual(RoutingMath.matrix(for: ChannelRouting()), .identity)
    }

    func testMuteFollowsSourceChannel() {
        var r = ChannelRouting()
        r.leftEnabled = false
        XCTAssertEqual(RoutingMath.matrix(for: r), GainMatrix(ll: 0, rl: 0, lr: 0, rr: 1))
        r = ChannelRouting(); r.rightEnabled = false
        XCTAssertEqual(RoutingMath.matrix(for: r), GainMatrix(ll: 1, rl: 0, lr: 0, rr: 0))
        // Swapped + source L muted: L would have gone out the RIGHT side, so the right output is silent.
        r = ChannelRouting(leftEnabled: false, rightEnabled: true, swapped: true, gainDB: 0)
        XCTAssertEqual(RoutingMath.matrix(for: r), GainMatrix(ll: 0, rl: 1, lr: 0, rr: 0))
    }

    func testSwapCrossesThePair() {
        let r = ChannelRouting(leftEnabled: true, rightEnabled: true, swapped: true, gainDB: 0)
        XCTAssertEqual(RoutingMath.matrix(for: r), GainMatrix(ll: 0, rl: 1, lr: 1, rr: 0))
    }

    func testGain() {
        XCTAssertEqual(RoutingMath.linearGain(dB: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(RoutingMath.linearGain(dB: -6), 0.501187, accuracy: 1e-5)
        XCTAssertEqual(RoutingMath.linearGain(dB: 6), 1.995262, accuracy: 1e-5)
        XCTAssertEqual(RoutingMath.linearGain(dB: -.infinity), 0)
        XCTAssertEqual(RoutingMath.linearGain(dB: .nan), 0)
        let m = RoutingMath.matrix(for: ChannelRouting(gainDB: -6))
        XCTAssertEqual(m.ll, 0.501187, accuracy: 1e-5)
        XCTAssertEqual(m.rr, 0.501187, accuracy: 1e-5)
    }

    func testPackRoundTrip() {
        for r in [ChannelRouting(), ChannelRouting(leftEnabled: false, rightEnabled: true, swapped: true, gainDB: -3.5),
                  ChannelRouting(leftEnabled: true, rightEnabled: false, swapped: false, gainDB: -.infinity),
                  ChannelRouting(leftEnabled: false, rightEnabled: false, swapped: true, gainDB: 6)] {
            XCTAssertEqual(RoutingMath.unpack(RoutingMath.pack(r)), r)
        }
    }

    func testRampReachesTargetLinearly() {
        var ramp = GainRamp(rampFrames: 480)
        ramp.setTarget(RoutingMath.matrix(for: ChannelRouting(swapped: true)))
        let n = 600
        let ones = [Float](repeating: 1, count: n)
        let zeros = [Float](repeating: 0, count: n)
        var outL = [Float](repeating: 0, count: n), outR = [Float](repeating: 0, count: n)
        // Source L = 1, R = 0: out L fades 1→0, out R fades 0→1 (a crossfade, no click).
        ramp.process(srcL: ones, srcR: zeros, outL: &outL, outR: &outR, count: n)
        XCTAssertEqual(outL[0], 1 - 1.0 / 480, accuracy: 1e-5)
        XCTAssertEqual(outR[239], 0.5, accuracy: 1e-3)
        for i in 1..<480 {
            XCTAssertLessThanOrEqual(outL[i], outL[i - 1] + 1e-6)
            XCTAssertGreaterThanOrEqual(outR[i], outR[i - 1] - 1e-6)
            XCTAssertEqual(outL[i] + outR[i], 1, accuracy: 1e-4)
        }
        XCTAssertEqual(outL[479], 0)
        XCTAssertEqual(outR[479], 1)
        XCTAssertTrue(ramp.isSettled)
        XCTAssertEqual(ramp.current, ramp.target)
        XCTAssertEqual(outL[599], 0)
        XCTAssertEqual(outR[599], 1)
    }

    func testRampSplitAcrossBlocksMatchesSingleBlock() {
        var a = GainRamp(rampFrames: 480), b = GainRamp(rampFrames: 480)
        let target = RoutingMath.matrix(for: ChannelRouting(leftEnabled: false, gainDB: -6))
        a.setTarget(target); b.setTarget(target)
        let src = (0..<1000).map { Float(sin(Double($0) * 0.1)) }
        var oa = [Float](repeating: 0, count: 1000), oaR = oa, ob = oa, obR = oa
        a.process(srcL: src, srcR: src, outL: &oa, outR: &oaR, count: 1000)
        var off = 0
        for size in [1, 64, 127, 300, 508] {
            src.withUnsafeBufferPointer { s in
                ob.withUnsafeMutableBufferPointer { o in obR.withUnsafeMutableBufferPointer { oR in
                    b.process(srcL: s.baseAddress! + off, srcR: s.baseAddress! + off,
                              outL: o.baseAddress! + off, outR: oR.baseAddress! + off, count: size)
                } }
            }
            off += size
        }
        for i in 0..<1000 {
            XCTAssertEqual(oa[i], ob[i], accuracy: 1e-5)
            XCTAssertEqual(oaR[i], obR[i], accuracy: 1e-5)
        }
    }

    func testRetargetMidRampHasNoJump() {
        var ramp = GainRamp(rampFrames: 100)
        ramp.setTarget(.silent)
        let ones = [Float](repeating: 1, count: 200)
        var l = [Float](repeating: 0, count: 200), r = l
        ramp.process(srcL: ones, srcR: ones, outL: &l, outR: &r, count: 50)
        let mid = l[49]
        ramp.setTarget(.identity)
        l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
            ramp.process(srcL: ones, srcR: ones, outL: lb.baseAddress! + 50, outR: rb.baseAddress! + 50, count: 150)
        } }
        XCTAssertEqual(l[50], mid, accuracy: 0.02)
        XCTAssertEqual(l[199], 1)
    }

    func testScalarRamp() {
        var g = ScalarRamp(0)
        g.ramp(to: 1, frames: 10)
        var a = [Float](repeating: 1, count: 20), b = a
        g.apply(&a, &b, count: 20)
        XCTAssertEqual(a[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(a[9], 1)
        XCTAssertEqual(a[19], 1)
        XCTAssertTrue(g.isSettled)
    }
}
