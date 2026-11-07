import Foundation

/// Wire protocol between a master (the device playing the show) and followers (crew devices).
/// JSON, one envelope per message. Versioned: `v` is checked before the body is decoded.
enum CrewProtocol {
    /// Bump when a change would make an older follower misread a message.
    static let version = 1
    /// Oldest version this build still understands.
    static let minimumVersion = 1
    /// Bonjour service type (must match NSBonjourServices in Info.plist).
    static let bonjourType = "_tcplayback._tcp"
}

enum CrewTransportState: String, Codable, Equatable { case stopped, playing, paused }

/// Where the master's show is: at master host time `anchorHost` the track was at
/// `anchorTrackTime`, moving at `rate` (1 while playing, 0 while stopped or paused).
struct CrewShowState: Codable, Equatable {
    var trackID: UUID?
    var transport: CrewTransportState
    var anchorTrackTime: TimeInterval
    var anchorHost: TimeInterval
    var rate: Double
    /// Increments on every seek / track change, so a follower snaps instead of slewing.
    var epoch: Int = 0

    func trackTime(atMasterHost h: TimeInterval) -> TimeInterval { anchorTrackTime + (h - anchorHost) * rate }
}

/// A track's cues, all lanes. Followers filter by role.
struct CrewCueList: Codable, Equatable {
    var trackID: UUID
    var trackName: String
    var cues: [CrewCue]
    /// Lane names and colours, so a follower can label lanes it has never seen.
    var lanes: [CuePointType]
}

/// Clock-sync request: follower's send time.
struct CrewPing: Codable, Equatable { var id: UInt32; var t0: TimeInterval }
/// Reply: the follower's t0, master receive time t1 and master send time t2.
struct CrewPong: Codable, Equatable { var id: UInt32; var t0: TimeInterval; var t1: TimeInterval; var t2: TimeInterval }

struct CrewHeartbeat: Codable, Equatable {
    var host: TimeInterval
    var deviceName: String
    var isMaster: Bool
}

struct CrewHello: Codable, Equatable {
    var deviceName: String
    var sessionID: UUID
    /// Role the follower has picked (nil = none yet).
    var roleID: UUID?
}

enum CrewMessage: Equatable {
    case hello(CrewHello)
    case showState(CrewShowState)
    case cueList(CrewCueList)
    case roles([CrewRole])
    case heartbeat(CrewHeartbeat)
    case ping(CrewPing)
    case pong(CrewPong)
    /// A message type from a newer build at the same protocol version. Ignored, not an error.
    case unknown(type: String)

    var type: String {
        switch self {
        case .hello: "hello"; case .showState: "showState"; case .cueList: "cueList"; case .roles: "roles"
        case .heartbeat: "heartbeat"; case .ping: "ping"; case .pong: "pong"; case .unknown(let t): t
        }
    }
}

struct CrewEnvelope: Equatable {
    var v: Int = CrewProtocol.version
    var sender: UUID
    var seq: UInt64
    var message: CrewMessage
}

enum CrewCodecError: Error, Equatable {
    /// The sender speaks a newer protocol than this build understands. Tell the user to update.
    case versionTooNew(Int)
    /// The sender is older than `CrewProtocol.minimumVersion`.
    case versionTooOld(Int)
    case malformed
}

extension CrewEnvelope: Codable {
    private enum K: String, CodingKey { case v, sender, seq, type, body }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        v = try c.decode(Int.self, forKey: .v)
        sender = try c.decode(UUID.self, forKey: .sender)
        seq = try c.decode(UInt64.self, forKey: .seq)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello": message = .hello(try c.decode(CrewHello.self, forKey: .body))
        case "showState": message = .showState(try c.decode(CrewShowState.self, forKey: .body))
        case "cueList": message = .cueList(try c.decode(CrewCueList.self, forKey: .body))
        case "roles": message = .roles(try c.decode([CrewRole].self, forKey: .body))
        case "heartbeat": message = .heartbeat(try c.decode(CrewHeartbeat.self, forKey: .body))
        case "ping": message = .ping(try c.decode(CrewPing.self, forKey: .body))
        case "pong": message = .pong(try c.decode(CrewPong.self, forKey: .body))
        default: message = .unknown(type: type)
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(v, forKey: .v); try c.encode(sender, forKey: .sender); try c.encode(seq, forKey: .seq)
        try c.encode(message.type, forKey: .type)
        switch message {
        case .hello(let b): try c.encode(b, forKey: .body)
        case .showState(let b): try c.encode(b, forKey: .body)
        case .cueList(let b): try c.encode(b, forKey: .body)
        case .roles(let b): try c.encode(b, forKey: .body)
        case .heartbeat(let b): try c.encode(b, forKey: .body)
        case .ping(let b): try c.encode(b, forKey: .body)
        case .pong(let b): try c.encode(b, forKey: .body)
        case .unknown: break
        }
    }
}

enum CrewCodec {
    static func encode(_ e: CrewEnvelope) throws -> Data { try JSONEncoder().encode(e) }

    /// Checks the version first, so a newer sender gets a clear error instead of a decode failure.
    static func decode(_ data: Data) -> Result<CrewEnvelope, CrewCodecError> {
        struct Version: Decodable { var v: Int }
        guard let ver = try? JSONDecoder().decode(Version.self, from: data) else { return .failure(.malformed) }
        if ver.v > CrewProtocol.version { return .failure(.versionTooNew(ver.v)) }
        if ver.v < CrewProtocol.minimumVersion { return .failure(.versionTooOld(ver.v)) }
        guard let e = try? JSONDecoder().decode(CrewEnvelope.self, from: data) else { return .failure(.malformed) }
        return .success(e)
    }
}
