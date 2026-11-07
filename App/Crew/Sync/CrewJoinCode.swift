import Foundation
import UIKit

/// What a follower needs to join a master, carried in a QR code shown on the master.
/// Encoded as `tcplayback-crew://join?d=<base64url JSON>`.
struct CrewJoinCode: Codable, Equatable {
    var v: Int = CrewProtocol.version
    var sessionID: UUID
    /// Bonjour service name to look for.
    var serviceName: String
    /// Direct address, for networks where Bonjour is blocked.
    var host: String?
    var port: UInt16?
    /// Short pairing code (future TLS-PSK); nil = open session.
    var pin: String?

    static let scheme = "tcplayback-crew"

    enum DecodeError: Error, Equatable { case notACrewCode, versionTooNew(Int), malformed }

    func urlString() throws -> String {
        let json = try JSONEncoder().encode(self)
        return "\(Self.scheme)://join?d=\(Self.base64url(json))"
    }

    static func decode(_ s: String) -> Result<CrewJoinCode, DecodeError> {
        guard let c = URLComponents(string: s), c.scheme == scheme, c.host == "join" else { return .failure(.notACrewCode) }
        guard let d = c.queryItems?.first(where: { $0.name == "d" })?.value, let data = unbase64url(d) else {
            return .failure(.malformed)
        }
        struct Version: Decodable { var v: Int }
        guard let ver = try? JSONDecoder().decode(Version.self, from: data) else { return .failure(.malformed) }
        if ver.v > CrewProtocol.version { return .failure(.versionTooNew(ver.v)) }
        guard let code = try? JSONDecoder().decode(CrewJoinCode.self, from: data) else { return .failure(.malformed) }
        return .success(code)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// STUB: QR image generation. Later: CIFilter.qrCodeGenerator() on `code.urlString()`, scaled
/// with nearest-neighbour so it stays sharp on the master's screen.
enum CrewQRImage {
    static func make(for code: CrewJoinCode, size: CGFloat = 240) -> UIImage? { nil }
}
