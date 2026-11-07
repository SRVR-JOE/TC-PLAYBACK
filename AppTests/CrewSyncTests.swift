import XCTest
import PDFKit
import TCKit
@testable import TCPlayback

final class CrewSyncTests: XCTestCase {
    // MARK: Schema

    func roundTrip(_ m: CrewMessage) throws -> CrewMessage {
        let env = CrewEnvelope(sender: UUID(), seq: 7, message: m)
        let data = try CrewCodec.encode(env)
        let back = try CrewCodec.decode(data).get()
        XCTAssertEqual(back.seq, 7); XCTAssertEqual(back.v, CrewProtocol.version); XCTAssertEqual(back.sender, env.sender)
        return back.message
    }

    func testSchemaRoundTrip() throws {
        let lane = CuePointType(name: "Shots", colorHex: "#9B6BFF")
        let cue = CrewCue(id: UUID(), time: 3.5, name: "Wide", laneID: lane.id, cueID: "4", colorHex: nil,
                          camera: 2, shotNumber: "12A", shotSize: "WS", shotNote: "slow", holdUntilNext: false)
        let messages: [CrewMessage] = [
            .hello(CrewHello(deviceName: "Cam 3 iPhone", sessionID: UUID(), roleID: UUID())),
            .showState(CrewShowState(trackID: UUID(), transport: .playing, anchorTrackTime: 12.25, anchorHost: 9999.5, rate: 1, epoch: 3)),
            .cueList(CrewCueList(trackID: UUID(), trackName: "Opener", cues: [cue], lanes: [lane])),
            .roles([CrewRole(name: "Cam 3", kind: .camera, cameraNumber: 3, colorHex: "#FFFFFF", laneIDs: [lane.id])]),
            .heartbeat(CrewHeartbeat(host: 1, deviceName: "Master", isMaster: true)),
            .ping(CrewPing(id: 9, t0: 1.25)),
            .pong(CrewPong(id: 9, t0: 1.25, t1: 2, t2: 2.001)),
        ]
        for m in messages { XCTAssertEqual(try roundTrip(m), m) }
    }

    func json(v: Int, type: String = "heartbeat", body: String = #"{"host":1,"deviceName":"x","isMaster":true}"#) -> Data {
        #"{"v":\#(v),"sender":"\#(UUID().uuidString)","seq":1,"type":"\#(type)","body":\#(body)}"#.data(using: .utf8)!
    }

    func testVersionMismatch() {
        XCTAssertNoThrow(try CrewCodec.decode(json(v: CrewProtocol.version)).get())
        XCTAssertEqual(CrewCodec.decode(json(v: CrewProtocol.version + 1)).failure, .versionTooNew(CrewProtocol.version + 1))
        XCTAssertEqual(CrewCodec.decode(json(v: 0)).failure, .versionTooOld(0))
        XCTAssertEqual(CrewCodec.decode(Data("nope".utf8)).failure, .malformed)
        XCTAssertEqual(CrewCodec.decode(json(v: 1, type: "showState", body: "{}")).failure, .malformed)
        // Unknown message type at the same version: decoded, ignored by sessions.
        XCTAssertEqual(try CrewCodec.decode(json(v: 1, type: "lyrics", body: "{}")).get().message, .unknown(type: "lyrics"))
    }

    func testFollowerRecordsVersionError() {
        let hub = LoopbackHub()
        let raw = hub.makeEndpoint("future-master")
        let f = CrewFollowerSession(transport: hub.makeEndpoint("f"), clock: { hub.now })
        raw.start(); f.start()
        raw.send(json(v: 99), to: f.transport.localID)
        hub.advance(by: 0.1)
        XCTAssertEqual(f.lastError, .versionTooNew(99))
    }

    // MARK: Clock sync

    func testClockSampleMaths() {
        // Master is 100 s ahead; 5 ms each way; 1 ms processing.
        let s = ClockSample(t0: 0, t1: 100.005, t2: 100.006, t3: 0.011)
        XCTAssertEqual(s.offset, 100, accuracy: 1e-9)
        XCTAssertEqual(s.roundTrip, 0.010, accuracy: 1e-9)
    }

    func testMedianFilterRejectsOutliers() {
        var e = ClockSyncEstimator(window: 9)
        XCTAssertNil(e.offset)
        for i in 0..<8 { e.add(ClockSample(t0: 0, t1: 50.002 + Double(i) * 0.0001, t2: 50.002 + Double(i) * 0.0001, t3: 0.004)) }
        e.add(ClockSample(t0: 0, t1: 50.4, t2: 50.4, t3: 0.5))   // one slow, asymmetric exchange
        XCTAssertEqual(e.offset!, 50.0, accuracy: 0.001)
        XCTAssertTrue(e.isSynced)
        e.add(ClockSample(t0: 1, t1: 0, t2: 0, t3: 0.5))         // negative round trip: dropped
        XCTAssertEqual(e.samples.count, 9)
    }

    // MARK: Follower clock

    func testFollowerClockSlewsSmallAndSnapsLarge() {
        var c = FollowerClock(snapThreshold: 0.05, slewRate: 0.1)
        XCTAssertNil(c.trackTime(atLocal: 0))
        c.apply(CrewShowState(trackID: nil, transport: .playing, anchorTrackTime: 0, anchorHost: 0, rate: 1), atLocal: 0)
        XCTAssertEqual(c.trackTime(atLocal: 1)!, 1, accuracy: 1e-9)
        // Offset estimate improves by 20 ms: no jump, bled in at 10%.
        c.updateOffset(0.02, atLocal: 1)
        XCTAssertEqual(c.trackTime(atLocal: 1)!, 1, accuracy: 1e-9)
        XCTAssertEqual(c.trackTime(atLocal: 1.1)!, 1.1 + 0.01, accuracy: 1e-9)
        XCTAssertEqual(c.trackTime(atLocal: 2)!, 2.02, accuracy: 1e-9)
        // Big correction snaps.
        c.updateOffset(1.0, atLocal: 2)
        XCTAssertEqual(c.trackTime(atLocal: 2)!, 3, accuracy: 1e-9)
        // A seek (new epoch) snaps even when small.
        c.apply(CrewShowState(trackID: nil, transport: .playing, anchorTrackTime: 3.01, anchorHost: 3, rate: 1, epoch: 1), atLocal: 2)
        XCTAssertEqual(c.trackTime(atLocal: 2)!, 3.01, accuracy: 1e-9)
        // Paused: rate 0 holds.
        c.apply(CrewShowState(trackID: nil, transport: .paused, anchorTrackTime: 5, anchorHost: 3, rate: 0, epoch: 1), atLocal: 2)
        XCTAssertEqual(c.trackTime(atLocal: 50)!, 5, accuracy: 1e-9)
    }

    // MARK: Loopback

    func testLoopbackSyncUnderJitterStaysWithin5ms() {
        for seed in [1, 2, 3, 42] as [UInt64] {
            let r = CrewLoopbackDemo.run(duration: 20, trueOffset: 1234.5678, baseDelay: 0.003, jitter: 0.008, seed: seed)
            XCTAssertLessThan(r.maxErrorAfterSync, 0.005, "seed \(seed): \(r)")
            XCTAssertEqual(r.estimatedOffset, r.trueOffset, accuracy: 0.004)
        }
    }

    func testLateJoinerGetsCurrentState() {
        let hub = LoopbackHub()
        let m = CrewMasterSession(transport: hub.makeEndpoint("m"), clock: { hub.now })
        m.start()
        let lane = CuePointType(name: "Shots", colorHex: "#FFFFFF")
        m.publish(roles: [CrewRole(name: "Cam 1", kind: .camera, cameraNumber: 1, colorHex: "#FFFFFF")])
        m.publish(CrewCueList(trackID: UUID(), trackName: "T", cues: [], lanes: [lane]))
        m.publish(CrewShowState(trackID: nil, transport: .paused, anchorTrackTime: 42, anchorHost: 0, rate: 0))
        hub.advance(by: 1)
        let f = CrewFollowerSession(transport: hub.makeEndpoint("f"), clock: { hub.now })
        f.start()
        f.join(m.transport.localID, hello: CrewHello(deviceName: "f", sessionID: m.sessionID, roleID: nil))
        hub.advance(by: 1)
        XCTAssertEqual(f.roles.first?.name, "Cam 1")
        XCTAssertEqual(f.cues?.trackName, "T")
        XCTAssertEqual(f.trackTime()!, 42, accuracy: 1e-9)
        XCTAssertNotNil(m.followers[f.transport.localID])
    }

    // MARK: Join code

    func testJoinCodeRoundTrip() throws {
        let code = CrewJoinCode(sessionID: UUID(), serviceName: "FOH iPad", host: "192.168.1.20", port: 51234, pin: "4821")
        let s = try code.urlString()
        XCTAssertTrue(s.hasPrefix("tcplayback-crew://join?d="))
        let payload = s.components(separatedBy: "?d=")[1]
        XCTAssertFalse(payload.contains { "+/=".contains($0) }, payload)
        XCTAssertEqual(CrewJoinCode.decode(s).success, code)
        XCTAssertEqual(CrewJoinCode.decode("https://example.com").failure, .notACrewCode)
        XCTAssertEqual(CrewJoinCode.decode("tcplayback-crew://join?d=!!!").failure, .malformed)
        var future = code; future.v = 99
        XCTAssertEqual(CrewJoinCode.decode(try future.urlString()).failure, .versionTooNew(99))
        XCTAssertNil(CrewQRImage.make(for: code))   // stub
    }

    func testNetworkFraming() {
        let framed = CrewNetworkTransport.frame(Data([1, 2, 3]))
        XCTAssertEqual(Array(framed), [0, 0, 0, 3, 1, 2, 3])
    }

    // MARK: Cue sheet PDF

    func testCueSheetPDFPageCountFor100Rows() throws {
        let lane = CuePointType(name: "Shots", colorHex: "#FFFFFF")
        let cues = (0..<100).map { i in
            CrewCue(id: UUID(), time: Double(i) * 2, name: "Shot \(i + 1)", laneID: lane.id, camera: i % 4 + 1,
                    shotNumber: String(i + 1), shotSize: "MS")
        }
        let role = CrewRole(name: "Cam 2", kind: .camera, cameraNumber: 2, colorHex: "#FFFFFF", laneIDs: [lane.id])
        let rows = CueSheetRenderer.rows(cues: cues, role: role, lanes: [lane], clock: CuePointClock(start: Timecode(hours: 1, rate: .fps25)))
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(rows.filter(\.highlighted).count, 25)
        XCTAssertEqual(rows[1].detail, "Cam 2 · MS")
        let r = CueSheetRenderer()
        XCTAssertEqual(r.rowsOnFirstPage, 33)
        XCTAssertEqual(r.rowsPerPage, 37)
        XCTAssertEqual(r.pageCount(rows: 100), 3)
        XCTAssertEqual(r.pageCount(rows: 0), 1)
        let data = r.render(title: "Show", track: "Opener", roleName: role.name, rows: rows)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 3)
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(page.string?.contains("Cue sheet for Cam 2") ?? false)
        XCTAssertTrue(doc.page(at: 2)?.string?.contains("Shot 100") ?? false)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
    var success: Success? { if case .success(let v) = self { return v }; return nil }
}
