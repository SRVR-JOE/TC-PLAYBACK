import Foundation
import Observation
import UIKit

// The shot reference page: a library of named shots with a description and a picture, to show
// operators what "MCU" or "cowboy" means on this show. Each shot has a drawn framing diagram, and
// the operator can replace it with a photo (a real frame grab from the show).

/// What the built-in diagram draws.
enum ShotFraming: String, Codable, CaseIterable, Identifiable, Sendable {
    case ecu, cu, mcu, ms, cowboy, wide, extremeWide, twoShot, group, ots, crowd, lowAngle, highAngle, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ecu: "Extreme close-up"; case .cu: "Close-up"; case .mcu: "Medium close-up"; case .ms: "Medium shot"
        case .cowboy: "Cowboy"; case .wide: "Wide"; case .extremeWide: "Extreme wide"; case .twoShot: "Two-shot"
        case .group: "Group"; case .ots: "Over the shoulder"; case .crowd: "Crowd"; case .lowAngle: "Low angle"
        case .highAngle: "High angle"; case .none: "No diagram"
        }
    }
}

struct ShotReference: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var abbr: String = ""
    var description: String = ""
    var framing: ShotFraming = .none
    /// File name of the operator's photo in the library's image folder; nil = the diagram.
    var imageFile: String? = nil

    init(name: String, abbr: String = "", description: String = "", framing: ShotFraming = .none) {
        self.name = name; self.abbr = abbr; self.description = description; self.framing = framing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        abbr = try c.decodeIfPresent(String.self, forKey: .abbr) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        framing = (try? c.decodeIfPresent(ShotFraming.self, forKey: .framing)) ?? .none
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
    }

    /// "Medium close-up · MCU".
    var title: String { abbr.isEmpty ? name : "\(name) · \(abbr)" }

    static let defaults: [ShotReference] = [
        .init(name: "Extreme close-up", abbr: "ECU", description: "A detail only: eyes, lips on the mic, hands on the keys or strings. Use for a moment, not a song.", framing: .ecu),
        .init(name: "Close-up", abbr: "CU", description: "Face fills the frame, cut at the top of the shoulders. Emotion and the big notes.", framing: .cu),
        .init(name: "Medium close-up", abbr: "MCU", description: "Chest up, eyes on the top third. The main IMAG shot for a singer.", framing: .mcu),
        .init(name: "Medium shot", abbr: "MS", description: "Waist up. Room for the mic hand and gestures.", framing: .ms),
        .init(name: "Cowboy", abbr: "MWS", description: "Mid-thigh up. Room for dancing, jumping and hands in the air.", framing: .cowboy),
        .init(name: "Wide", abbr: "WS", description: "Head to toe with room around them. Movement and choreography.", framing: .wide),
        .init(name: "Extreme wide", abbr: "EWS", description: "The whole stage and the crowd. The safety and the beauty shot.", framing: .extremeWide),
        .init(name: "Two-shot", abbr: "2S", description: "Two people in one frame: the artist with a guest or band member.", framing: .twoShot),
        .init(name: "Group", description: "Three or more: horns, background singers, the whole band.", framing: .group),
        .init(name: "Over the shoulder", abbr: "OTS", description: "From behind the artist, past the shoulder, out to the crowd.", framing: .ots),
        .init(name: "Crowd", description: "Fans with hands up and singing, stage light on them. Between songs and on sing-alongs.", framing: .crowd),
        .init(name: "Low angle", description: "From below, looking up. Makes the artist big. Pit cameras.", framing: .lowAngle),
        .init(name: "High angle", description: "From above, looking down: jib over the crowd or the stage.", framing: .highAngle),
    ]
}

@MainActor
@Observable
final class ShotLibraryStore {
    static let shared = ShotLibraryStore()

    private(set) var shots: [ShotReference] = []
    @ObservationIgnored private let directory: URL?

    /// `directory` nil = memory only (tests without files).
    init(directory: URL? = ShotLibraryStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ShotLibrary", isDirectory: true)
    }

    private var fileURL: URL? { directory?.appendingPathComponent("shots.json") }
    var imagesDirectory: URL? { directory?.appendingPathComponent("images", isDirectory: true) }

    private func load() {
        guard let u = fileURL, let d = try? Data(contentsOf: u),
              let s = try? JSONDecoder().decode([ShotReference].self, from: d) else {
            shots = ShotReference.defaults
            return
        }
        shots = s
    }

    private func persist() {
        guard let u = fileURL else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(shots).write(to: u, options: .atomic)
    }

    func save(_ shot: ShotReference) {
        if let i = shots.firstIndex(where: { $0.id == shot.id }) { shots[i] = shot } else { shots.append(shot) }
        persist()
    }

    func delete(_ shot: ShotReference) {
        removeImageFile(shot.imageFile)
        shots.removeAll { $0.id == shot.id }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        var a = shots
        let moving = from.sorted().map { a[$0] }
        for i in from.sorted(by: >) { a.remove(at: i) }
        let dest = to - from.filter { $0 < to }.count
        a.insert(contentsOf: moving, at: max(0, min(dest, a.count)))
        shots = a
        persist()
    }

    /// Puts back the built-in shots the library no longer has (by name); keeps the operator's own.
    func restoreDefaults() {
        for d in ShotReference.defaults where !shots.contains(where: { $0.name.caseInsensitiveCompare(d.name) == .orderedSame }) {
            shots.append(d)
        }
        persist()
    }

    // MARK: Photos

    func imageURL(_ shot: ShotReference) -> URL? {
        guard let f = shot.imageFile else { return nil }
        return imagesDirectory?.appendingPathComponent(f)
    }

    func image(_ shot: ShotReference) -> UIImage? {
        imageURL(shot).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// Stores a photo for a shot (scaled to 1600 px on the long side, JPEG) and returns the shot
    /// with its new image file. The old photo is removed.
    @discardableResult
    func setPhoto(_ data: Data, for shot: ShotReference) throws -> ShotReference {
        guard let img = UIImage(data: data) else { throw ShotLibraryError.notAnImage }
        guard let dir = imagesDirectory else { throw ShotLibraryError.noStorage }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpeg = Self.scaled(img, maxSide: 1600).jpegData(compressionQuality: 0.85) ?? data
        let name = "\(shot.id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
        try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
        var s = shot
        removeImageFile(s.imageFile)
        s.imageFile = name
        save(s)
        return s
    }

    @discardableResult
    func removePhoto(_ shot: ShotReference) -> ShotReference {
        var s = shot
        removeImageFile(s.imageFile)
        s.imageFile = nil
        save(s)
        return s
    }

    private func removeImageFile(_ f: String?) {
        guard let f, let dir = imagesDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
    }

    nonisolated static func scaled(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height, 1))
        guard k < 1 else { return img }
        let size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

enum ShotLibraryError: LocalizedError {
    case notAnImage, noStorage
    var errorDescription: String? {
        switch self {
        case .notAnImage: "That file isn’t a picture."
        case .noStorage: "Couldn’t save the picture."
        }
    }
}
