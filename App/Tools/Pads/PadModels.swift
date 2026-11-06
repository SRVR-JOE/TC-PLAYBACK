import Foundation
import SwiftUI
import TCKit

// TC Pads data model. Persisted as plain Codable JSON in Application Support (not SwiftData):
// the pad banks are a small, self-contained document and must survive schema changes in the
// show library.

/// Colour tag shown as a thin strip on a pad. Muted, state-neutral hues only.
enum PadColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, grey
    var id: String { rawValue }

    var label: String { self == .none ? "None" : rawValue.capitalized }

    var color: Color {
        switch self {
        case .none: Theme.hairline
        case .red: Color(hex: 0xC4493F)
        case .orange: Color(hex: 0xC97A2B)
        case .yellow: Color(hex: 0xC2A532)
        case .green: Color(hex: 0x4E9A5E)
        case .teal: Color(hex: 0x3F948F)
        case .blue: Color(hex: 0x4A78B8)
        case .purple: Color(hex: 0x8460B0)
        case .grey: Color(hex: 0x7A8088)
        }
    }
}

/// One timecode preset.
struct TCPad: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    /// Start timecode. Its `rate` is ignored at fire time — the effective rate (override or bank)
    /// is applied via `TCPad.conform(_:to:)`.
    var start: Timecode
    /// nil = use the bank rate.
    var rateOverride: FrameRate?
    var side: OutputSide = .right
    var levelDBFS: Float = -10
    /// Run time after the cue point, seconds. nil = run until stopped.
    var duration: TimeInterval?
    var color: PadColor = .none
    /// Seconds of pre-roll before the cue point. nil = use the bank setting.
    var preRollOverride: Double?

    func rate(in bank: PadBank) -> FrameRate { rateOverride ?? bank.rate }
    func preRoll(in bank: PadBank) -> Double { preRollOverride ?? bank.preRollSeconds }

    /// The start timecode expressed at the pad's effective rate.
    func startTimecode(in bank: PadBank) -> Timecode { TCPad.conform(start, to: rate(in: bank)) }

    /// Re-express a timecode's digits at another rate, clamping frames that don't exist there
    /// (e.g. frame 29 at 25 fps → 24, or a dropped DF label → frame 02).
    static func conform(_ tc: Timecode, to rate: FrameRate) -> Timecode {
        var f = min(tc.frames, rate.nominalFPS - 1)
        if rate.isDropFrame, tc.seconds == 0, f < 2, tc.minutes % 10 != 0 { f = 2 }
        return Timecode(hours: min(tc.hours, 23), minutes: min(tc.minutes, 59),
                        seconds: min(tc.seconds, 59), frames: f, rate: rate)
    }
}

/// A bank of pads (tab A, B, C…). Rate and pre-roll are bank defaults; pads may override.
struct PadBank: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var rate: FrameRate = .fps30
    var preRollSeconds: Double = 0
    var pads: [TCPad] = []

    /// "Hours 1–10": 01:00:00:00 … 10:00:00:00.
    static func hourPads(rate: FrameRate, side: OutputSide = .right) -> [TCPad] {
        (1...10).map { h in
            TCPad(label: "Hour \(h)", start: Timecode(hours: h, rate: rate), side: side)
        }
    }
}

/// The whole pad document.
struct PadLibrary: Codable, Equatable {
    var version = 1
    var banks: [PadBank]
    var selectedBankID: UUID?

    static let maxBanks = 8

    static func makeDefault() -> PadLibrary {
        let a = PadBank(name: "A", rate: .fps30, pads: PadBank.hourPads(rate: .fps30))
        return PadLibrary(banks: [a, PadBank(name: "B"), PadBank(name: "C")], selectedBankID: a.id)
    }

    /// Next unused single-letter bank name.
    func nextBankName() -> String {
        let used = Set(banks.map(\.name))
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            let s = String(UnicodeScalar(scalar)!)
            if !used.contains(s) { return s }
        }
        return "\(banks.count + 1)"
    }
}

/// JSON persistence for `PadLibrary`.
struct PadStore {
    let url: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TCPads", isDirectory: true).appendingPathComponent("banks.json")
    }

    init(url: URL = PadStore.defaultURL) { self.url = url }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func load() -> PadLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PadLibrary.self, from: data)
    }

    func save(_ library: PadLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PadStore.encoder().encode(library)
        try data.write(to: url, options: .atomic)
    }
}
