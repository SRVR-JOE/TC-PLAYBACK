import Foundation
import Observation
import UIKit

// The camera brief (camera plot) for a show: each camera's call name, who's on it, where it is,
// and its mission. One per playlist. The names are also the cue caller's camera keys: what a
// key inserts into a call and what the voice says.

enum CameraKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case handheld, hard, jib, ptz, steadicam, drone, robo, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .handheld: "Handheld"; case .hard: "Hard"; case .jib: "Jib"; case .ptz: "PTZ"
        case .steadicam: "Steadicam"; case .drone: "Drone"; case .robo: "Robo"; case .other: "Other"
        }
    }
}

struct BriefCamera: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Camera number, 1…12 for the caller's keys (more are allowed).
    var number: Int
    /// What the camera is called over comms. Blank = "Camera N".
    var name: String = ""
    var operatorName: String = ""
    var position: String = ""
    var kind: CameraKind = .handheld
    var lens: String = ""
    var subject: String = ""
    /// The directions: what this camera is for, in a few lines.
    var mission: String = ""
    /// A mark colour (`CuePointColor` hex); nil = none.
    var colorHex: String? = nil

    static func defaultName(_ n: Int) -> String { "Camera \(n)" }
    /// The call name, never blank.
    var callName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? Self.defaultName(number) : n
    }
    /// "Handheld · FOH riser · Sam · 24–70": the quieter line on a card.
    var detailLine: String {
        [kind.label, position, operatorName, lens].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(number: Int, name: String = "", operatorName: String = "", position: String = "", kind: CameraKind = .handheld,
         lens: String = "", subject: String = "", mission: String = "", colorHex: String? = nil) {
        self.number = number; self.name = name; self.operatorName = operatorName; self.position = position
        self.kind = kind; self.lens = lens; self.subject = subject; self.mission = mission; self.colorHex = colorHex
    }

    // Tolerant decoding: fields added later default instead of failing the whole brief.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        kind = (try? c.decodeIfPresent(CameraKind.self, forKey: .kind)) ?? .other
        lens = try c.decodeIfPresent(String.self, forKey: .lens) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        mission = try c.decodeIfPresent(String.self, forKey: .mission) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

struct CameraBrief: Codable, Equatable, Sendable {
    /// Card order (the page's order; numbers are the identity for the keys).
    var cameras: [BriefCamera] = []
    var updatedAt = Date()

    init(cameras: [BriefCamera] = []) { self.cameras = cameras }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameras = try c.decodeIfPresent([BriefCamera].self, forKey: .cameras) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func camera(number: Int) -> BriefCamera? { cameras.first { $0.number == number } }

    /// The next free number (for "Add camera").
    var nextNumber: Int { ((cameras.map(\.number).max() ?? 0) + 1) }

    /// The twelve key names: the brief's call names, "Camera N" for numbers it doesn't have.
    var keyNames: [String] {
        (1...CueCameraPresets.count).map { camera(number: $0)?.callName ?? BriefCamera.defaultName($0) }
    }

    /// The four cameras from the Macklemore brief (the one-time seed and the screenshot data).
    static let macklemore = CameraBrief(cameras: [
        BriefCamera(number: 1, subject: "Macklemore",
                    mission: "Macklemore all night. Mid to tight shots. When his hands go up, zoom out to get them in."),
        BriefCamera(number: 2, subject: "Macklemore", mission: "Macklemore wide to mid. Keep the crowd in the bottom of the shot."),
        BriefCamera(number: 3, subject: "Macklemore", mission: "Macklemore, plus drummer and horn pickups."),
        BriefCamera(number: 4, subject: "Macklemore", mission: "Macklemore, horns, background singers and DJ."),
    ])

    #if DEBUG
    /// Screenshot data: the Macklemore four with positions filled in.
    static var preview: CameraBrief {
        var b = macklemore
        let extra: [(CameraKind, String, String, String?)] = [
            (.handheld, "Pit", "Dani", CuePointColor.amber.rawValue), (.hard, "FOH riser", "Marco", CuePointColor.blue.rawValue),
            (.handheld, "Stage left", "Jo", CuePointColor.green.rawValue), (.jib, "Stage right", "Priya", CuePointColor.purple.rawValue),
        ]
        for i in b.cameras.indices {
            (b.cameras[i].kind, b.cameras[i].position, b.cameras[i].operatorName, b.cameras[i].colorHex) = extra[i]
        }
        return b
    }
    #endif
}

/// Briefs as JSON, one file per playlist under Application Support/CameraBriefs. A brief for "no
/// playlist" lives under `defaultID`.
@MainActor
@Observable
final class CameraBriefStore {
    static let shared = CameraBriefStore()
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000CA4E0")!
    static let macklemoreSeededKey = "cameraBrief.macklemoreSeeded"

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let defaults: UserDefaults
    /// Told about every change (the cue caller re-reads camera names).
    @ObservationIgnored var onChange: (() -> Void)?
    private var briefs: [UUID: CameraBrief] = [:]
    @ObservationIgnored private var loaded: Set<UUID> = []

    /// `directory` nil = memory only (tests).
    init(directory: URL? = CameraBriefStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CameraBriefs", isDirectory: true)
    }

    private func url(_ id: UUID) -> URL? { directory?.appendingPathComponent("\(id.uuidString).json") }

    private func load(_ id: UUID) {
        guard !loaded.contains(id) else { return }
        loaded.insert(id)
        guard let u = url(id), let d = try? Data(contentsOf: u) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let b = try? dec.decode(CameraBrief.self, from: d) { briefs[id] = b }
    }

    /// The playlist the caller and the page use when none is given.
    var currentID: UUID { ShowController.shared.playlist?.id ?? Self.defaultID }

    func hasBrief(_ id: UUID) -> Bool { load(id); return briefs[id] != nil }

    /// The brief for a playlist (empty when it has none yet).
    func brief(_ id: UUID? = nil) -> CameraBrief {
        let k = id ?? currentID
        load(k)
        return briefs[k] ?? CameraBrief()
    }

    func set(_ brief: CameraBrief, for id: UUID? = nil) {
        let k = id ?? currentID
        load(k)
        var b = brief
        b.updatedAt = .now
        briefs[k] = b
        if let u = url(k) {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? enc.encode(b).write(to: u, options: .atomic)
        }
        onChange?()
    }

    func update(_ id: UUID? = nil, _ change: (inout CameraBrief) -> Void) {
        var b = brief(id)
        change(&b)
        set(b, for: id)
    }

    /// Set a camera's call name from the keys (adds the camera to the brief when it isn't there).
    func rename(number: Int, to name: String, in id: UUID? = nil) {
        update(id) { b in
            if let i = b.cameras.firstIndex(where: { $0.number == number }) { b.cameras[i].name = name }
            else { b.cameras.append(BriefCamera(number: number, name: name)); b.cameras.sort { $0.number < $1.number } }
        }
    }

    /// Once ever: a playlist called "Macklemore" with no brief gets the four Macklemore cameras.
    /// Returns the playlist id it seeded. The flag is set as soon as such a playlist is found, so
    /// a brief edited (or emptied) later is never touched again.
    @discardableResult
    func seedMacklemoreOnce(playlists: [(id: UUID, name: String)]) -> UUID? {
        guard !defaults.bool(forKey: Self.macklemoreSeededKey) else { return nil }
        guard let p = playlists.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Macklemore") == .orderedSame
        }) else { return nil }
        defaults.set(true, forKey: Self.macklemoreSeededKey)
        guard !hasBrief(p.id) else { return nil }
        set(CameraBrief.macklemore, for: p.id)
        return p.id
    }
}

// MARK: - PDF

/// A printable camera brief: show name, date, one card per camera. US Letter, as many pages as
/// the missions need.
enum CameraBriefPDF {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let margin: CGFloat = 48

    /// Writes the PDF to a temporary file and returns its URL (`usb` hooks "Save to USB" here).
    static func makeURL(brief: CameraBrief, showName: String, date: Date = .now) throws -> URL {
        let name = ShowPackage.safeName(showName.isEmpty ? "Cameras" : showName)
        let url = URL.temporaryDirectory.appending(path: "\(name) camera brief.pdf")
        try data(brief: brief, showName: showName, date: date).write(to: url, options: .atomic)
        return url
    }

    static func data(brief: CameraBrief, showName: String, date: Date = .now) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(showName) camera brief", kCGPDFContextCreator as String: "TC Playback"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { ctx in
            let width = page.width - margin * 2
            var y = margin
            func newPage() { ctx.beginPage(); y = margin }
            newPage()
            // Header
            let title = NSAttributedString(string: showName.isEmpty ? "Camera brief" : showName,
                                           attributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: UIColor.black])
            title.draw(at: CGPoint(x: margin, y: y)); y += 28
            let sub = NSAttributedString(string: "Camera brief · " + date.formatted(date: .long, time: .omitted),
                                         attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray])
            sub.draw(at: CGPoint(x: margin, y: y)); y += 22
            rule(at: y, width: width); y += 14
            if brief.cameras.isEmpty {
                NSAttributedString(string: "No cameras in this brief yet.", attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray])
                    .draw(at: CGPoint(x: margin, y: y))
            }
            for cam in brief.cameras {
                let card = cardText(cam)
                let h = ceil(card.boundingRect(with: CGSize(width: width - 14, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], context: nil).height)
                if y + h + 18 > page.height - margin { newPage() }
                if let hex = cam.colorHex, let c = UIColor(hexString: hex) {
                    c.setFill(); UIRectFill(CGRect(x: margin, y: y + 2, width: 4, height: h - 2))
                }
                card.draw(with: CGRect(x: margin + 14, y: y, width: width - 14, height: h), options: [.usesLineFragmentOrigin], context: nil)
                y += h + 10
                rule(at: y, width: width); y += 12
            }
        }
    }

    private static func rule(at y: CGFloat, width: CGFloat) {
        UIColor(white: 0.82, alpha: 1).setFill()
        UIRectFill(CGRect(x: margin, y: y, width: width, height: 0.5))
    }

    static func cardText(_ cam: BriefCamera) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3; para.paragraphSpacing = 2
        func add(_ t: String, _ f: UIFont, _ c: UIColor = .black) {
            s.append(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: para]))
        }
        add("\(cam.number)   ", .monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .darkGray)
        add(cam.callName, .systemFont(ofSize: 17, weight: .semibold))
        if !cam.subject.trimmingCharacters(in: .whitespaces).isEmpty { add("   " + cam.subject, .systemFont(ofSize: 13, weight: .medium), .darkGray) }
        add("\n", .systemFont(ofSize: 6))
        let mission = cam.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        add((mission.isEmpty ? "No mission written yet." : mission) + "\n", .systemFont(ofSize: 13), mission.isEmpty ? .gray : .black)
        if !cam.detailLine.isEmpty { add(cam.detailLine, .systemFont(ofSize: 10), .gray) }
        return s
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
