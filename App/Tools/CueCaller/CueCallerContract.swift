import Foundation

// CONTRACT (cue caller team build). Shared types for the engine, language and UI parts.
// Additive only: change these in a coordinated way, not per-agent.
//
// The cue caller follows timecode (this app's playback, or LTC coming in on an input), and
// speaks each mark's `callNote` over comms: a standby a few seconds ahead, then the call itself
// timed so its last word ("go") lands on the mark. Each area (cameras, LX, SFX, a language
// group) has its own language, voice and output channels, so one note can go to an
// English camera ring and a Spanish one at the same time.

/// Where the caller gets time from.
enum CueCallerSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// This app's own playback (heard position, the same reference as triggers).
    case playback
    /// LTC arriving on an audio input (another machine is the master).
    case ltcInput
    var id: String { rawValue }
    var label: String { self == .playback ? "This app's playback" : "LTC input" }
}

/// One comms destination: a language, a voice and the output channels wired to that ring.
struct CueCallArea: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// BCP-47 language for this area ("en-US", "es-MX", "fr-FR", "de-DE", "ja-JP").
    var language: String
    /// AVSpeechSynthesisVoice identifier; nil = best installed voice for `language`.
    var voiceID: String? = nil
    /// Zero-based hardware output channels this area is spoken on (into the comms interface).
    var outputChannels: [Int] = [0, 1]
    /// Cue types (lanes) this area calls; empty = every lane.
    var laneIDs: [UUID] = []
    var enabled = true
    /// Level trim for this area's calls.
    var gainDB: Double = 0
    /// Speaking rate, 0.3...0.65 (AVSpeechUtterance rate scale; 0.5 = default).
    var rate: Float = 0.52
}

/// Everything the caller remembers. Stored as JSON in UserDefaults under `key`.
struct CueCallerSettings: Codable, Equatable, Sendable {
    static let key = "cueCaller.settings"

    /// Master toggle. Off by default — nothing speaks until the operator engages it.
    var enabled = false
    var source: CueCallerSource = .playback
    /// Seconds before the mark to say "Standby …".
    var standbyLead: Double = 5
    var sayStandby = true
    /// Prefix the call with the mark name when the note is empty ("Chorus 1 — go").
    var includeMarkName = false
    /// Calls only on the area channels; never mixed into program outputs.
    var dedicatedCallChannels = true
    /// Speak only marks that have a call note.
    var onlyMarksWithNotes = true
    var areas: [CueCallArea] = [CueCallArea(name: "Cameras", language: "en-US")]
    /// Marks in one area within a frame of each other are called as one stack (one standby,
    /// one go) instead of the later one cutting the earlier one off.
    var stackSameFrame = true

    static func load(_ d: UserDefaults = .standard) -> CueCallerSettings {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(CueCallerSettings.self, from: data) else { return .init() }
        return s
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

extension CueCallerSettings {
    /// Fields missing from older saved settings keep their defaults (instead of the whole
    /// decode failing and resetting the operator's areas).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CueCallerSettings()
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        source = try c.decodeIfPresent(CueCallerSource.self, forKey: .source) ?? d.source
        standbyLead = try c.decodeIfPresent(Double.self, forKey: .standbyLead) ?? d.standbyLead
        sayStandby = try c.decodeIfPresent(Bool.self, forKey: .sayStandby) ?? d.sayStandby
        includeMarkName = try c.decodeIfPresent(Bool.self, forKey: .includeMarkName) ?? d.includeMarkName
        dedicatedCallChannels = try c.decodeIfPresent(Bool.self, forKey: .dedicatedCallChannels) ?? d.dedicatedCallChannels
        onlyMarksWithNotes = try c.decodeIfPresent(Bool.self, forKey: .onlyMarksWithNotes) ?? d.onlyMarksWithNotes
        areas = try c.decodeIfPresent([CueCallArea].self, forKey: .areas) ?? d.areas
        stackSameFrame = try c.decodeIfPresent(Bool.self, forKey: .stackSameFrame) ?? d.stackSameFrame
    }
}

/// A single scheduled utterance for one area.
struct CueCall: Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case standby, go }
    let markID: UUID
    let areaID: UUID
    let kind: Kind
    /// Track time (seconds) the call is aimed at. For `.go` this is the mark time — the
    /// renderer's speech ends with the go word landing here. For `.standby`, mark − lead.
    let at: TimeInterval
    /// Final text in the area's language.
    let text: String
    /// Calls stacked in this utterance (1 = a plain call).
    var lineCount = 1
}

/// Turns the operator's note into an area's language. Implementations cache, and must return
/// the input unchanged when source and target are the same language.
protocol CueCallTranslator: Sendable {
    func translate(_ text: String, from: String, to: String) async throws -> String
}

/// Renders text to mono float PCM at `sampleRate`, ready to schedule on an output channel.
protocol CueCallVoiceRenderer: Sendable {
    func render(_ text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> [Float]
}
