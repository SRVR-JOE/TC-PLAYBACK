import AVFoundation
import Foundation
import Observation
import SwiftData

/// UI state for ElevenLabs voices: the key, the account status line, the voice lists, preparing
/// calls for offline use, and calls that fell back to the device voice. Views talk to this and
/// `CueCallerUIModel`; this talks to the ElevenLabs client, its cache and the engine.
@MainActor
@Observable
final class CueCallVoicesModel {
    static let shared = CueCallVoicesModel()

    enum Connection: Equatable {
        case noKey
        case checking
        case connected(charactersLeft: Int)
        case failed(String)

        var label: String {
            switch self {
            case .noKey: "No key entered"
            case .checking: "Checking…"
            case .connected(let n): "Connected · \(n.formatted(.number)) characters left this month"
            case .failed(let m): m
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let client: ElevenLabsClient
    @ObservationIgnored let renderer: ElevenLabsCueCallRenderer
    @ObservationIgnored let router: CueCallVoiceRouter
    static let namesKey = "cueCaller.eleven.voiceNames"

    init(defaults: UserDefaults = .standard, client: ElevenLabsClient = .shared,
         renderer: ElevenLabsCueCallRenderer = .shared, router: CueCallVoiceRouter = .shared) {
        self.defaults = defaults
        self.client = client
        self.renderer = renderer
        self.router = router
        preferences = ElevenLabsPreferences.load(defaults)
        names = (defaults.dictionary(forKey: Self.namesKey) as? [String: String]) ?? [:]
        let key = ElevenLabsKeychain.currentKey() != nil
        hasKey = key
        connection = key ? .checking : .noKey
    }

    // MARK: Key

    private(set) var hasKey: Bool
    private(set) var connection: Connection
    /// The key in use came from the DEBUG environment / launch argument, not the Keychain.
    var keyIsForTesting: Bool { ElevenLabsKeychain.read() == nil && ElevenLabsKeychain.debugKey != nil }

    func saveKey(_ key: String) {
        guard ElevenLabsKeychain.save(key) else { connection = .failed("The key couldn’t be saved on this iPad."); return }
        hasKey = true
        refreshStatus()
        loadAccountVoices()
    }

    func removeKey() {
        ElevenLabsKeychain.remove()
        hasKey = ElevenLabsKeychain.currentKey() != nil
        accountVoices = []
        connection = hasKey ? .checking : .noKey
        if hasKey { refreshStatus() }
    }

    /// DEBUG screenshots: hold the seeded state, no network.
    @ObservationIgnored private var frozen = false

    /// Free ElevenLabs accounts can't use library voices through the API (built-in voices only).
    var isFreePlan = false

    func refreshStatus() {
        if frozen { return }
        guard hasKey else { connection = .noKey; return }
        connection = .checking
        Task {
            do {
                let s = try await client.subscription()
                isFreePlan = (s.tier ?? "").lowercased() == "free"
                connection = .connected(charactersLeft: s.charactersLeft)
            } catch {
                connection = .failed(Self.message(error))
            }
        }
    }

    // MARK: Model and voice settings

    var preferences: ElevenLabsPreferences {
        didSet { if preferences != oldValue { preferences.save(defaults); refreshReadiness() } }
    }

    var model: ElevenLabsModel {
        get { ElevenLabsModel(rawValue: preferences.model) ?? .multilingualV2 }
        set { preferences.model = newValue.rawValue }
    }

    // MARK: Account voices

    private(set) var accountVoices: [ElevenLabsVoice] = []
    private(set) var loadingVoices = false
    private(set) var voicesError: String?

    func loadAccountVoices() {
        guard hasKey, !loadingVoices, !frozen else { return }
        loadingVoices = true
        Task {
            defer { loadingVoices = false }
            do {
                accountVoices = try await client.accountVoices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                voicesError = nil
                for v in accountVoices { remember(v.voiceID, name: v.name) }
            } catch {
                voicesError = Self.message(error)
            }
        }
    }

    /// Names of voices picked before, so a picker can label a voice while offline.
    private var names: [String: String] { didSet { defaults.set(names, forKey: Self.namesKey) } }
    func remember(_ elevenID: String, name: String) { if names[elevenID] != name { names[elevenID] = name } }
    func voiceName(_ elevenID: String) -> String { names[elevenID] ?? accountVoices.first { $0.voiceID == elevenID }?.name ?? "ElevenLabs voice" }

    // MARK: Shared library

    private(set) var sharedVoices: [ElevenLabsSharedVoice] = []
    private(set) var searching = false
    private(set) var searchError: String?
    private(set) var adding: String?

    func searchShared(language: String, gender: String?) async {
        searching = true
        defer { searching = false }
        do {
            sharedVoices = try await client.sharedVoices(.forArea(language: language, gender: gender))
            searchError = sharedVoices.isEmpty ? "No shared voices found for this language." : nil
        } catch {
            sharedVoices = []
            searchError = Self.message(error)
        }
    }

    /// Adds a shared voice to the account and returns its area voice id ("eleven:…").
    func add(_ v: ElevenLabsSharedVoice) async -> String? {
        if accountVoices.contains(where: { $0.voiceID == v.voiceID }) { remember(v.voiceID, name: v.name); return ElevenLabsVoiceID.tag(v.voiceID) }
        adding = v.voiceID
        defer { adding = nil }
        do {
            let id = try await client.addSharedVoice(publicOwnerID: v.publicOwnerID, voiceID: v.voiceID, name: v.name)
            remember(id, name: v.name)
            loadAccountVoices()
            return ElevenLabsVoiceID.tag(id)
        } catch {
            searchError = Self.message(error)
            return nil
        }
    }

    // MARK: Preview (device only, never in the simulator)

    @ObservationIgnored private var player: AVPlayer?
    private(set) var previewing: String?

    static var canPreview: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !ProcessInfo.processInfo.arguments.contains("-silentOutput")
        #endif
    }

    func preview(_ id: String, url: String?) {
        guard Self.canPreview, let s = url, let u = URL(string: s) else { return }
        if previewing == id { stopPreview(); return }
        let p = AVPlayer(url: u)
        player = p
        previewing = id
        p.play()
    }

    func stopPreview() { player?.pause(); player = nil; previewing = nil }

    // MARK: Prepare calls

    private(set) var preparing = false
    private(set) var prepareDone = 0
    private(set) var prepareTotal = 0
    /// ElevenLabs calls on disk for the current track, of all its ElevenLabs calls.
    private(set) var readyOffline = 0
    private(set) var elevenCallCount = 0
    private(set) var prepareError: String?
    private(set) var prepareTrackTitle: String?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    /// Marks to prepare when none are given: what the caller has loaded, else the show's
    /// playing or standby track.
    func currentMarks() -> (title: String?, marks: [CueCallMark]) {
        let caller = CueCaller.shared
        if !caller.loadedMarks.isEmpty { return (caller.trackTitle, caller.loadedMarks) }
        let show = ShowController.shared
        if let t = (show.activeCue ?? show.standbyCue)?.track, let ctx = t.modelContext {
            return (t.title, CuePoint.points(for: t.id, in: ctx).map(CueCallMark.init))
        }
        return (nil, [])
    }

    /// The ElevenLabs requests a track's calls need, one per distinct line.
    func requests(marks: [CueCallMark]) async -> [ElevenLabsSpeechRequest] {
        let caller = CueCaller.shared
        let settings = caller.settings
        guard settings.areas.contains(where: { $0.enabled && ElevenLabsVoiceID.isEleven($0.voiceID) }) else { return [] }
        let prepared = await CueCallScheduler.prepare(marks: marks, settings: settings, noteLanguage: caller.noteLanguage,
                                                      translator: caller.translator, phrase: caller.phrase)
        var seen = Set<String>(), out: [ElevenLabsSpeechRequest] = []
        for p in prepared {
            guard let area = settings.areas.first(where: { $0.id == p.call.areaID }),
                  case .eleven(let id) = CueCallVoiceRouter.route(area.voiceID) else { continue }
            let r = renderer.request(text: p.call.text, language: area.language, voiceID: id, rate: area.rate)
            if seen.insert(r.cacheKey).inserted { out.append(r) }
        }
        return out
    }

    /// Recount "N of M calls ready offline".
    func refreshReadiness(marks given: [CueCallMark]? = nil, title: String? = nil) {
        if frozen { return }
        let cur = given.map { (title, $0) } ?? currentMarks()
        Task {
            let rs = await requests(marks: cur.1)
            elevenCallCount = rs.count
            readyOffline = rs.filter { renderer.isReady($0) }.count
            prepareTrackTitle = cur.0
        }
    }

    /// Render every ElevenLabs call of the track (every enabled area) while online.
    func prepareCalls(marks given: [CueCallMark]? = nil, title: String? = nil) {
        guard !preparing else { return }
        let cur = given.map { (title, $0) } ?? currentMarks()
        preparing = true
        prepareError = nil
        prepareDone = 0
        prepareTotal = 0
        prepareTrackTitle = cur.0
        prepareTask = Task {
            let rs = await requests(marks: cur.1)
            prepareTotal = rs.count
            elevenCallCount = rs.count
            var failures = 0
            for r in rs {
                if Task.isCancelled { break }
                if !renderer.isReady(r) {
                    do { _ = try await renderer.speech(for: r) } catch {
                        failures += 1
                        prepareError = Self.message(error)
                        if let e = error as? ElevenLabsError, [.offline, .unauthorized, .quotaExceeded, .noKey].contains(e) { break }
                    }
                }
                prepareDone += 1
            }
            readyOffline = rs.filter { renderer.isReady($0) }.count
            if failures == 0 { prepareError = nil }
            preparing = false
            router.clearFallbacks()
            CueCaller.shared.reloadRenders()
            refreshStatus()
        }
    }

    func cancelPrepare() { prepareTask?.cancel() }

    /// "12 of 14 calls ready offline".
    var readinessLine: String {
        if elevenCallCount == 0 { return "No calls use an ElevenLabs voice yet." }
        return "\(readyOffline) of \(elevenCallCount) call\(elevenCallCount == 1 ? "" : "s") ready offline"
    }

    // MARK: Fallbacks

    private(set) var fallbackCount = 0
    func refreshFallbacks() { fallbackCount = router.fallbackCount }

    /// "2 calls used the device voice", nil when none did.
    var fallbackLine: String? {
        guard fallbackCount > 0 else { return nil }
        return "\(fallbackCount) call\(fallbackCount == 1 ? "" : "s") used the device voice"
    }

    // MARK: Helpers

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    #if DEBUG
    /// Screenshot data (`-cueCallerPreview`): never touches the network.
    func seedPreview() {
        frozen = true
        connection = .connected(charactersLeft: 84_210)
        hasKey = true
        accountVoices = [
            ElevenLabsVoice(voiceID: "preview-anna", name: "Anna · Zürich", category: "professional", description: nil, previewURL: nil, labels: ["accent": "swiss"]),
            ElevenLabsVoice(voiceID: "preview-erik", name: "Erik", category: "professional", description: nil, previewURL: nil, labels: ["accent": "swedish"]),
            ElevenLabsVoice(voiceID: "preview-james", name: "James", category: "premade", description: nil, previewURL: nil, labels: ["accent": "british"]),
        ]
        for v in accountVoices { remember(v.voiceID, name: v.name) }
        sharedVoices = [
            .init(publicOwnerID: "o1", voiceID: "s1", name: "Anna · Zürich", accent: "swiss", gender: "female", age: "middle_aged",
                  language: "de", locale: "de-CH", description: "Calm, clear Swiss Standard German. Good for announcements.",
                  previewURL: nil, useCase: "informative_educational", usage1y: 4_200_000, clonedBy: 1800),
            .init(publicOwnerID: "o2", voiceID: "s2", name: "Lukas", accent: "swiss", gender: "male", age: "young",
                  language: "de", locale: "de-CH", description: "Friendly Bernese speaker, steady pace.",
                  previewURL: nil, useCase: "conversational", usage1y: 2_900_000, clonedBy: 950),
            .init(publicOwnerID: "o3", voiceID: "s3", name: "Mira", accent: "swiss", gender: "female", age: "young",
                  language: "de", locale: "de-CH", description: "Bright, direct. Swiss accent, standard vocabulary.",
                  previewURL: nil, useCase: "narrative_story", usage1y: 1_100_000, clonedBy: 410),
        ]
        elevenCallCount = 14
        readyOffline = 12
        fallbackCount = 2
        prepareTrackTitle = "Chorus drop"
    }
    #endif
}
