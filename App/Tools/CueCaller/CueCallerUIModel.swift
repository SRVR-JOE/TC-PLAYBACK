import AVFoundation
import Foundation
import Observation
import Translation
import TCKit

// ============================================================================================
// SEAM FILE (cue caller team build) — the ONLY place the cue caller UI touches the engine
// (CueCaller.shared, ~/tc-call-engine) and the language layer (translator, overrides, voices,
// ~/tc-call-lang). Every view in CueCallerViews.swift / CueCallsReview.swift talks to
// `CueCallerUIModel.shared` and nothing else.
//
// Until merge, the members marked `// SEAM:` are stand-ins that read/write CueCallerSettings
// directly and derive state from PlaybackEngine. At merge, point each marked member at the
// real implementation (the comment on each says what it expects).
// ============================================================================================

/// What the caller is doing right now (shown on the playback screen control).
enum CueCallerStatus: Equatable, Sendable {
    case off
    /// Engaged and following timecode.
    case following
    /// Engaged, but no timecode yet (playback stopped, or no LTC on the input).
    case waiting
    /// Engaged, was following, and the timecode stopped or jumped.
    case lost

    var label: String {
        switch self {
        case .off: "Off"
        case .following: "On · following"
        case .waiting: "Waiting for timecode"
        case .lost: "Timecode lost"
        }
    }
}

/// The next thing the caller will say.
struct CueCallerUpcoming: Equatable, Sendable {
    var markID: UUID
    var markName: String
    /// The note in the operator's language (or the mark name when there's no note).
    var text: String
    var kind: CueCall.Kind
    /// Seconds until the call's target time (the mark for `.go`, mark − lead for `.standby`).
    var secondsToGo: Double
}

/// The last thing the caller said.
struct CueCallerLastCall: Equatable, Sendable {
    var text: String
    var areaName: String
    var kind: CueCall.Kind
}

struct CueCallVoiceChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// "Premium" / "Enhanced" / "Standard".
    let quality: String
}

/// Whether notes can be translated into an area's language on this device.
enum CueCallTranslationStatus: Equatable, Sendable {
    case checking
    /// Area speaks the note language: nothing to translate.
    case sameLanguage
    case ready
    case downloadNeeded
    case unsupported

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .sameLanguage: "Same as notes"
        case .ready: "Ready offline"
        case .downloadNeeded: "Download needed"
        case .unsupported: "Not available on this device"
        }
    }
}

/// One hardware output channel on the current audio interface.
struct CueCallOutputChannel: Identifiable, Hashable, Sendable {
    /// Zero-based, as stored in `CueCallArea.outputChannels`.
    let id: Int
    /// "1", "2"… or the interface's own name for the channel.
    let name: String
}

@MainActor
@Observable
final class CueCallerUIModel {
    static let shared = CueCallerUIModel(engine: .shared)

    @ObservationIgnored private let defaults: UserDefaults
    /// The live caller. nil in unit tests, which keep settings in their own defaults.
    @ObservationIgnored private let engine: CueCaller?
    static let noteLanguageKey = "cueCaller.noteLanguage"
    static let overridesKey = "cueCaller.ui.overrides"

    init(defaults: UserDefaults = .standard, engine: CueCaller? = nil) {
        self.defaults = defaults
        self.engine = engine
        settings = engine?.settings ?? CueCallerSettings.load(defaults)
        noteLanguage = defaults.string(forKey: Self.noteLanguageKey) ?? "en-US"
        overrides = (defaults.dictionary(forKey: Self.overridesKey) as? [String: String]) ?? [:]
        engine?.noteLanguage = noteLanguage
    }

    // MARK: Settings

    /// SEAM: expects `CueCaller.shared.settings` (get/set, persisted by the engine). Today: saved here.
    var settings: CueCallerSettings {
        didSet {
            guard settings != oldValue else { return }
            if let engine { engine.settings = settings } else { settings.save(defaults) }
        }
    }

    /// The language the operator writes call notes in.
    /// SEAM: expects the language layer's source language if it keeps one; else keep this.
    var noteLanguage: String {
        didSet {
            defaults.set(noteLanguage, forKey: Self.noteLanguageKey)
            engine?.noteLanguage = noteLanguage
        }
    }

    /// Master toggle.
    var isEngaged: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue }
    }

    // MARK: Live state

    /// SEAM: expects `CueCaller.shared.status` (off / following / waiting / lost).
    var status: CueCallerStatus {
        guard settings.enabled else { return .off }
        if let engine {
            switch engine.status {
            case .following: return .following
            case .timecodeLost: return .lost
            case .idle, .waitingForTimecode: return .waiting
            }
        }
        let e = PlaybackEngine.shared
        switch settings.source {
        case .playback:
            return e.transport == .playing ? .following : .waiting
        case .ltcInput:
            guard e.clock.source == .externalInput else { return .waiting }
            switch e.clock.lock {
            case .locked: return .following
            case .freewheel: return .lost
            default: return .waiting
            }
        }
    }

    /// SEAM: expects `CueCaller.shared.lastCall`.
    var lastCall: CueCallerLastCall? {
        guard let c = engine?.lastCall else { return nil }
        return CueCallerLastCall(text: c.text, areaName: area(c.areaID)?.name ?? "", kind: c.kind)
    }

    /// SEAM: expects `CueCaller.shared.nextCall` (with live seconds to go). nil here: the playback
    /// strip falls back to its own next-mark-with-a-note readout.
    var nextCall: CueCallerUpcoming? {
        guard let engine, let c = engine.nextCall, let startsIn = engine.nextCallIn else { return nil }
        // nextCallIn counts to the first word; show the countdown to the call's target instead.
        let start = engine.timeline.first { $0.call == c }?.start ?? c.at
        return CueCallerUpcoming(markID: c.markID, markName: "", text: c.text, kind: c.kind,
                                 secondsToGo: max(0, startsIn + (c.at - start)))
    }

    // MARK: Actions

    /// SEAM: expects `CueCaller.shared.test(areaID:)` — speaks a short test call on the area's
    /// channels with its voice, rate and gain. Today: nothing is spoken (the stand-in can't reach
    /// the area's output channels, and the simulator must stay silent).
    func test(area: CueCallArea) {
        lastTestAreaID = area.id
        engine?.test(area: area)
    }
    private(set) var lastTestAreaID: UUID?

    // MARK: Voices

    /// SEAM: expects the language layer's voice list for a language (`SpeechCueCallRenderer`).
    /// Today: installed system voices for that language, best quality first.
    func voices(for language: String) -> [CueCallVoiceChoice] {
        if engine != nil {
            return SpeechCueCallRenderer.voices(for: language)
                .map { CueCallVoiceChoice(id: $0.id, name: $0.name, quality: $0.qualityLabel) }
        }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .filter { !$0.identifier.contains("speech.synthesis") }
        let exact = all.filter { $0.language == language }
        let pool = exact.isEmpty ? all.filter { $0.language.hasPrefix(base) } : exact
        return pool
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { CueCallVoiceChoice(id: $0.identifier, name: $0.name, quality: Self.qualityLabel($0.quality)) }
    }

    nonisolated static func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q { case .premium: "Premium"; case .enhanced: "Enhanced"; default: "Standard" }
    }

    // MARK: Translation

    /// SEAM: expects the language layer's availability check (`AppleCueCallTranslator`).
    /// Today: Apple's Translation framework directly.
    func translationStatus(for language: String) async -> CueCallTranslationStatus {
        if Self.sameLanguage(language, noteLanguage) { return .sameLanguage }
        if engine != nil {
            switch await AppleCueCallTranslator.shared.status(from: noteLanguage, to: language) {
            case .same: return .sameLanguage
            case .installed: return .ready
            case .needsDownload: return .downloadNeeded
            case .unsupported: return .unsupported
            }
        }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: noteLanguage),
                                                         to: Locale.Language(identifier: language))
        switch status {
        case .installed: return .ready
        case .supported: return .downloadNeeded
        default: return .unsupported
        }
    }

    /// SEAM: expects the language layer's cached translation of `text` into `language` (nil when
    /// not translated yet). Today: nil unless the languages match.
    func translation(of text: String, to language: String) async -> String? {
        if Self.sameLanguage(language, noteLanguage) { return text }
        guard engine != nil else { return nil }
        let t = AppleCueCallTranslator.shared
        if let cached = CueCallTranslationStore.shared.cached(text, from: noteLanguage, to: language) { return cached }
        guard case .installed = await t.status(from: noteLanguage, to: language) else { return nil }
        return try? await t.translate(text, from: noteLanguage, to: language)
    }

    nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
        a.split(separator: "-").first?.lowercased() == b.split(separator: "-").first?.lowercased()
    }

    // MARK: Manual overrides (per mark, per language)

    /// SEAM: expects the language layer's override store (get/set by mark id + language).
    private var overrides: [String: String] {
        didSet { defaults.set(overrides, forKey: Self.overridesKey) }
    }
    private static func overrideKey(_ mark: UUID, _ language: String) -> String { "\(mark.uuidString)|\(language)" }

    func override(markID: UUID, language: String) -> String? {
        if engine != nil { return CueCallTranslationStore.shared.override(markID: markID, language: language)?.text }
        return overrides[Self.overrideKey(markID, language)]
    }

    /// nil or blank clears the override (back to the automatic translation).
    /// `note` is the mark's call note the correction was written for (a later edit of the note
    /// makes the correction stale, so a changed note is never called with an old translation).
    func setOverride(_ text: String?, markID: UUID, language: String, note: String = "") {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if engine != nil {
            CueCallTranslationStore.shared.setOverride(markID: markID, language: language, sourceText: note, text: t)
            return
        }
        overrides[Self.overrideKey(markID, language)] = t.isEmpty ? nil : t
    }

    // MARK: Output channels

    /// Channels of the current output route (names from the interface when it gives them).
    /// Not a seam: reads AVAudioSession, same as the engine. `including` keeps channels an area
    /// already uses visible (so they can be cleared) when the current interface has fewer.
    func outputChannels(including assigned: [Int] = []) -> [CueCallOutputChannel] {
        let count = max(interfaceOutputCount, (assigned.max() ?? -1) + 1)
        let named = AVAudioSession.sharedInstance().currentRoute.outputs.flatMap { $0.channels ?? [] }
        return (0..<count).map { i in
            let n = i < named.count ? named[i].channelName : ""
            let plain = n.isEmpty || n.lowercased().hasPrefix("channel") || n.lowercased().hasPrefix("output")
            return CueCallOutputChannel(id: i, name: plain ? "\(i + 1)" : "\(i + 1) \(n)")
        }
    }

    /// How many outputs the connected interface has.
    var interfaceOutputCount: Int {
        let session = AVAudioSession.sharedInstance()
        let named = session.currentRoute.outputs.flatMap { $0.channels ?? [] }
        return max(2, named.count, session.outputNumberOfChannels, session.maximumOutputNumberOfChannels)
    }

    /// The area's outputs the connected interface doesn't have (shown as a warning).
    func missingOutputs(_ area: CueCallArea) -> [Int] {
        let n = interfaceOutputCount
        return area.outputChannels.filter { $0 >= n }
    }

    // MARK: Areas

    @discardableResult
    func addArea(name: String? = nil, language: String? = nil) -> CueCallArea {
        let used = Set(settings.areas.flatMap(\.outputChannels))
        let next = (0..<64).first { !used.contains($0) && !used.contains($0 + 1) && $0.isMultiple(of: 2) } ?? 0
        let a = CueCallArea(name: uniqueAreaName(name ?? "Area \(settings.areas.count + 1)"),
                            language: language ?? noteLanguage, outputChannels: [next, next + 1])
        settings.areas.append(a)
        return a
    }

    func removeArea(_ id: UUID) { settings.areas.removeAll { $0.id == id } }

    func removeAreas(at offsets: IndexSet) {
        settings.areas = settings.areas.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    func moveAreas(from: IndexSet, to: Int) {
        var a = settings.areas
        let moving = from.map { a[$0] }
        let before = from.filter { $0 < to }.count
        for i in from.sorted(by: >) { a.remove(at: i) }
        a.insert(contentsOf: moving, at: max(0, min(a.count, to - before)))
        settings.areas = a
    }

    func setAreaEnabled(_ id: UUID, _ on: Bool) { updateArea(id) { $0.enabled = on } }

    func updateArea(_ id: UUID, _ change: (inout CueCallArea) -> Void) {
        guard let i = settings.areas.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.areas[i])
    }

    func area(_ id: UUID) -> CueCallArea? { settings.areas.first { $0.id == id } }

    /// Distinct area languages, in area order (columns of the Calls review).
    var areaLanguages: [String] {
        var seen = Set<String>(), out: [String] = []
        for a in settings.areas where seen.insert(a.language).inserted { out.append(a.language) }
        return out
    }

    private func uniqueAreaName(_ base: String) -> String {
        var name = base, n = 2
        while settings.areas.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    // MARK: Languages

    struct Language: Identifiable, Hashable, Sendable { let id: String; let name: String }

    /// Common show languages, in the order operators pick them.
    nonisolated static let commonLanguages: [Language] = [
        .init(id: "en-US", name: "English (US)"), .init(id: "en-GB", name: "English (UK)"),
        .init(id: "es-ES", name: "Spanish (Spain)"), .init(id: "es-MX", name: "Spanish (Mexico)"),
        .init(id: "fr-FR", name: "French"), .init(id: "de-DE", name: "German"), .init(id: "it-IT", name: "Italian"),
        .init(id: "pt-BR", name: "Portuguese (Brazil)"), .init(id: "ja-JP", name: "Japanese"), .init(id: "ko-KR", name: "Korean"),
        .init(id: "zh-CN", name: "Chinese (Mandarin)"), .init(id: "nl-NL", name: "Dutch"),
    ]

    /// Every other language the device has a voice for.
    nonisolated static var otherLanguages: [Language] {
        let common = Set(commonLanguages.map(\.id))
        let codes = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language)).subtracting(common)
        return codes.map { Language(id: $0, name: languageName($0)) }.sorted { $0.name < $1.name }
    }

    nonisolated static func languageName(_ code: String) -> String {
        if let c = commonLanguages.first(where: { $0.id == code }) { return c.name }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Short form for tight rows: "EN-US" style codes are developer-ish, so use the name.
    nonisolated static func shortLanguageName(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: base) ?? code
    }
}
