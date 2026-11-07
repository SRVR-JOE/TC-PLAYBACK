import Foundation

/// A device on the crew network.
struct CrewPeerID: Hashable, Codable, CustomStringConvertible {
    var raw: String
    var description: String { raw }
}

/// Moves encoded envelopes between master and followers. Unicast only: UDP multicast on iOS
/// needs Apple's multicast entitlement, so discovery is Bonjour and every send goes to a peer.
protocol CrewTransport: AnyObject {
    var localID: CrewPeerID { get }
    /// Called with each received message and who sent it.
    var onReceive: ((Data, CrewPeerID) -> Void)? { get set }
    /// Called when the set of connected peers changes.
    var onPeersChanged: (([CrewPeerID]) -> Void)? { get set }
    var peers: [CrewPeerID] { get }
    func start()
    func stop()
    /// `to: nil` sends to every connected peer.
    func send(_ data: Data, to peer: CrewPeerID?)
}

// MARK: - In-memory loopback (tests, previews)

/// A virtual network with its own clock. Messages are delivered when `advance` passes their
/// arrival time, so tests can model latency and jitter deterministically.
final class LoopbackHub {
    private(set) var now: TimeInterval = 0
    /// One-way delay for a message from → to. Default 1 ms.
    var delay: (CrewPeerID, CrewPeerID) -> TimeInterval = { _, _ in 0.001 }
    private var endpoints: [CrewPeerID: LoopbackTransport] = [:]
    private var queue: [(at: TimeInterval, seq: Int, to: CrewPeerID, from: CrewPeerID, data: Data)] = []
    private var seq = 0

    func makeEndpoint(_ name: String) -> LoopbackTransport {
        let t = LoopbackTransport(id: CrewPeerID(raw: name), hub: self)
        return t
    }

    fileprivate func attach(_ t: LoopbackTransport) {
        endpoints[t.localID] = t
        notifyPeers()
    }
    fileprivate func detach(_ t: LoopbackTransport) {
        endpoints[t.localID] = nil
        notifyPeers()
    }
    fileprivate func peers(of id: CrewPeerID) -> [CrewPeerID] {
        endpoints.keys.filter { $0 != id }.sorted { $0.raw < $1.raw }
    }
    fileprivate func enqueue(_ data: Data, from: CrewPeerID, to: CrewPeerID) {
        guard endpoints[to] != nil else { return }
        seq += 1
        queue.append((now + max(0, delay(from, to)), seq, to, from, data))
    }

    /// Runs the network forward by `dt`, delivering everything due, in arrival order.
    func advance(by dt: TimeInterval) { advance(to: now + dt) }

    func advance(to t: TimeInterval) {
        while let i = queue.indices.min(by: { (queue[$0].at, queue[$0].seq) < (queue[$1].at, queue[$1].seq) }),
              queue[i].at <= t {
            let m = queue.remove(at: i)
            now = max(now, m.at)
            endpoints[m.to]?.onReceive?(m.data, m.from)
        }
        now = max(now, t)
    }

    private func notifyPeers() {
        for (id, t) in endpoints { t.onPeersChanged?(peers(of: id)) }
    }
}

final class LoopbackTransport: CrewTransport {
    let localID: CrewPeerID
    var onReceive: ((Data, CrewPeerID) -> Void)?
    var onPeersChanged: (([CrewPeerID]) -> Void)?
    private weak var hub: LoopbackHub?
    private var running = false

    fileprivate init(id: CrewPeerID, hub: LoopbackHub) { localID = id; self.hub = hub }

    var peers: [CrewPeerID] { running ? (hub?.peers(of: localID) ?? []) : [] }
    func start() { guard !running else { return }; running = true; hub?.attach(self) }
    func stop() { guard running else { return }; running = false; hub?.detach(self) }
    func send(_ data: Data, to peer: CrewPeerID?) {
        guard running, let hub else { return }
        for p in peer.map({ [$0] }) ?? peers { hub.enqueue(data, from: localID, to: p) }
    }
}

// MARK: - Sessions (transport-agnostic protocol logic)

/// Master side: answers clock pings, publishes show state, cue lists and roles.
final class CrewMasterSession {
    let transport: CrewTransport
    let sessionID: UUID
    let senderID = UUID()
    /// Master host clock (monotonic seconds).
    private let clock: () -> TimeInterval
    private var seq: UInt64 = 0
    private(set) var followers: [CrewPeerID: CrewHello] = [:]
    var deviceName = "Master"
    /// The last of each, re-sent to followers that join late.
    private(set) var lastState: CrewShowState?
    private(set) var lastCues: CrewCueList?
    private(set) var lastRoles: [CrewRole]?
    private(set) var rejected: [CrewCodecError] = []

    init(transport: CrewTransport, sessionID: UUID = UUID(), clock: @escaping () -> TimeInterval) {
        self.transport = transport; self.sessionID = sessionID; self.clock = clock
        transport.onReceive = { [weak self] d, p in self?.receive(d, from: p) }
    }

    func start() { transport.start() }
    func stop() { transport.stop() }

    func publish(_ s: CrewShowState) { lastState = s; send(.showState(s), to: nil) }
    func publish(_ c: CrewCueList) { lastCues = c; send(.cueList(c), to: nil) }
    func publish(roles: [CrewRole]) { lastRoles = roles; send(.roles(roles), to: nil) }
    func heartbeat() { send(.heartbeat(CrewHeartbeat(host: clock(), deviceName: deviceName, isMaster: true)), to: nil) }

    private func receive(_ data: Data, from peer: CrewPeerID) {
        let t1 = clock()
        switch CrewCodec.decode(data) {
        case .failure(let e): rejected.append(e)
        case .success(let env):
            switch env.message {
            case .ping(let p):
                send(.pong(CrewPong(id: p.id, t0: p.t0, t1: t1, t2: clock())), to: peer)
            case .hello(let h):
                followers[peer] = h
                if let r = lastRoles { send(.roles(r), to: peer) }
                if let c = lastCues { send(.cueList(c), to: peer) }
                if let s = lastState { send(.showState(s), to: peer) }
            default: break
            }
        }
    }

    private func send(_ m: CrewMessage, to peer: CrewPeerID?) {
        seq += 1
        if let d = try? CrewCodec.encode(CrewEnvelope(sender: senderID, seq: seq, message: m)) { transport.send(d, to: peer) }
    }
}

/// Follower side: syncs its clock to the master, tracks show state, cues and roles.
final class CrewFollowerSession {
    let transport: CrewTransport
    let senderID = UUID()
    private let clock: () -> TimeInterval
    private var seq: UInt64 = 0
    private var pingID: UInt32 = 0
    private(set) var master: CrewPeerID?
    private(set) var sync = ClockSyncEstimator()
    private(set) var followerClock = FollowerClock()
    private(set) var cues: CrewCueList?
    private(set) var roles: [CrewRole] = []
    private(set) var lastHeartbeatAt: TimeInterval?
    /// Last version/decoding problem, for "update the app on this device" messaging.
    private(set) var lastError: CrewCodecError?
    var onChange: (() -> Void)?

    init(transport: CrewTransport, clock: @escaping () -> TimeInterval) {
        self.transport = transport; self.clock = clock
        transport.onReceive = { [weak self] d, p in self?.receive(d, from: p) }
    }

    func start() { transport.start() }
    func stop() { transport.stop() }

    /// Introduce ourselves to `master` (it replies with its current state).
    func join(_ master: CrewPeerID, hello: CrewHello) {
        self.master = master
        send(.hello(hello), to: master)
    }

    /// Send one clock-sync ping. Call a few times a second at first, then about once a second.
    func ping() {
        guard let master else { return }
        pingID &+= 1
        send(.ping(CrewPing(id: pingID, t0: clock())), to: master)
    }

    /// Track time to display now (nil before the first show state).
    func trackTime() -> TimeInterval? { followerClock.trackTime(atLocal: clock()) }
    func trackTime(atLocal t: TimeInterval) -> TimeInterval? { followerClock.trackTime(atLocal: t) }

    private func receive(_ data: Data, from peer: CrewPeerID) {
        let t3 = clock()
        switch CrewCodec.decode(data) {
        case .failure(let e): lastError = e
        case .success(let env):
            switch env.message {
            case .pong(let p):
                sync.add(ClockSample(t0: p.t0, t1: p.t1, t2: p.t2, t3: t3))
                if let o = sync.offset { followerClock.updateOffset(o, atLocal: t3) }
            case .showState(let s): followerClock.apply(s, atLocal: t3)
            case .cueList(let c): cues = c
            case .roles(let r): roles = r
            case .heartbeat: lastHeartbeatAt = t3
            default: break
            }
        }
        onChange?()
    }

    private func send(_ m: CrewMessage, to peer: CrewPeerID?) {
        seq += 1
        if let d = try? CrewCodec.encode(CrewEnvelope(sender: senderID, seq: seq, message: m)) { transport.send(d, to: peer) }
    }
}

// MARK: - Loopback demo (used by tests and the developer preview)

enum CrewLoopbackDemo {
    struct Result: Equatable {
        var maxErrorAfterSync: TimeInterval
        var estimatedOffset: TimeInterval
        var trueOffset: TimeInterval
        var medianRoundTrip: TimeInterval
    }

    /// Simulates a master and one follower over a jittery link for `duration` seconds of
    /// virtual time and measures how far the follower's track time is from the master's.
    /// Deterministic for a given `seed`.
    static func run(duration: TimeInterval = 20, trueOffset: TimeInterval = 1234.5678, baseDelay: TimeInterval = 0.003,
                    jitter: TimeInterval = 0.008, seed: UInt64 = 42) -> Result {
        var rng = SplitMix64(seed: seed)
        let hub = LoopbackHub()
        hub.delay = { _, _ in baseDelay + Double.random(in: 0...jitter, using: &rng) }
        let masterClock = { hub.now + trueOffset }
        let followerClock = { hub.now }
        let m = CrewMasterSession(transport: hub.makeEndpoint("master"), clock: masterClock)
        let f = CrewFollowerSession(transport: hub.makeEndpoint("follower"), clock: followerClock)
        m.start(); f.start()
        f.join(m.transport.localID, hello: CrewHello(deviceName: "Follower", sessionID: m.sessionID, roleID: nil))
        let trackStartHost = masterClock() + 0.5
        m.publish(CrewShowState(trackID: UUID(), transport: .playing, anchorTrackTime: 0, anchorHost: trackStartHost, rate: 1))

        var maxError: TimeInterval = 0
        let step = 0.01
        var t: TimeInterval = 0
        var i = 0
        while t < duration {
            if i % (t < 1 ? 5 : 20) == 0 { f.ping() }      // 20 Hz for the first second, then 5 Hz
            if i % 100 == 0 { m.heartbeat() }
            if i % 200 == 0 {                               // periodic re-anchor, as a real master would
                let h = masterClock()
                m.publish(CrewShowState(trackID: m.lastState?.trackID, transport: .playing,
                                        anchorTrackTime: h - trackStartHost, anchorHost: h, rate: 1))
            }
            hub.advance(by: step); t += step; i += 1
            if t > 2, let ft = f.trackTime() {
                let mt = masterClock() - trackStartHost
                maxError = max(maxError, abs(ft - mt))
            }
        }
        return Result(maxErrorAfterSync: maxError, estimatedOffset: f.sync.offset ?? .nan, trueOffset: trueOffset,
                      medianRoundTrip: f.sync.roundTrip ?? .nan)
    }
}

/// The output-test PRNG (TestSignals.swift) doubles as the simulation RNG.
extension SplitMix64: RandomNumberGenerator {}
