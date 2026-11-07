import Foundation
import Network

/// SKELETON — compiles, not production-ready. Bonjour `_tcplayback._tcp` discovery with
/// NWListener (master) / NWBrowser (follower) and TCP unicast with 4-byte big-endian length
/// framing. Not used anywhere in the shipping app (FeatureFlags.crewCueing gates all callers).
///
/// TODO before real use:
/// - Reconnect / backoff, connection timeouts, and a per-peer send queue.
/// - Clock pings over a UDP unicast connection (TCP's head-of-line blocking inflates RTT).
/// - Pairing check: reject peers whose hello carries the wrong session id from the QR code.
/// - TLS-PSK from the QR pin so a stray device can't join.
/// - Exercise the Local Network permission flow on a device (prompt is unavoidable).
final class CrewNetworkTransport: CrewTransport {
    enum Role { case master(serviceName: String), follower }

    let localID: CrewPeerID
    var onReceive: ((Data, CrewPeerID) -> Void)?
    var onPeersChanged: (([CrewPeerID]) -> Void)?
    /// Follower: services found on the network (shown in a join list).
    var onServicesFound: (([NWBrowser.Result]) -> Void)?

    private let role: Role
    private let queue = DispatchQueue(label: "crew.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [CrewPeerID: NWConnection] = [:]

    init(role: Role, deviceName: String) {
        self.role = role
        localID = CrewPeerID(raw: deviceName)
    }

    var peers: [CrewPeerID] { Array(connections.keys) }

    func start() {
        switch role {
        case .master(let name): startListener(name: name)
        case .follower: startBrowser()
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        publishPeers()
    }

    func send(_ data: Data, to peer: CrewPeerID?) {
        let targets = peer.map { p in connections[p].map { [$0] } ?? [] } ?? Array(connections.values)
        let framed = Self.frame(data)
        for c in targets { c.send(content: framed, completion: .contentProcessed { _ in }) }
    }

    /// Follower: connect to a service from the browser (or from a QR code's host/port).
    func connect(to endpoint: NWEndpoint) {
        let c = NWConnection(to: endpoint, using: .tcp)
        add(c)
    }

    // MARK: Private

    private func startListener(name: String) {
        guard let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: name, type: CrewProtocol.bonjourType)
        l.newConnectionHandler = { [weak self] c in self?.add(c) }
        l.start(queue: queue)
        listener = l
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: CrewProtocol.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = Array(results)
            DispatchQueue.main.async { self?.onServicesFound?(list) }
        }
        b.start(queue: queue)
        browser = b
    }

    private func add(_ c: NWConnection) {
        let id = CrewPeerID(raw: "\(c.endpoint)")
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.publishPeers()
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil; self?.publishPeers() }
            default: break
            }
        }
        c.start(queue: queue)
        receiveFrame(on: c, from: id)
    }

    private func receiveFrame(on c: NWConnection, from id: CrewPeerID) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, done, error in
            guard let self, let header, header.count == 4, error == nil else { return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length < 8 << 20 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                if let body, error == nil {
                    DispatchQueue.main.async { self.onReceive?(body, id) }
                }
                if !done { self.receiveFrame(on: c, from: id) }
            }
        }
    }

    private func publishPeers() {
        let list = peers
        DispatchQueue.main.async { self.onPeersChanged?(list) }
    }

    static func frame(_ data: Data) -> Data {
        var n = UInt32(data.count).bigEndian
        return Data(bytes: &n, count: 4) + data
    }
}
