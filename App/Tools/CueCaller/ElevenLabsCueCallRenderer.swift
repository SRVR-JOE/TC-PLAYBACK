import AVFoundation
import CryptoKit
import Foundation
import Security

// ElevenLabs voices for the cue caller. Calls are made with the text-to-speech "with timestamps"
// endpoint (PCM 24 kHz plus per-character timing, so the go word's onset is known), kept in a
// disk cache that survives relaunch, and processed exactly like the device voice (trim, fade,
// −16 LUFS / −1.5 dBFS) so both sources sound the same on comms.
//
// An area uses ElevenLabs when its `voiceID` is "eleven:<voice_id>"; any other id is an Apple
// voice. No schema change.

// MARK: - Voice ids

enum ElevenLabsVoiceID {
    static let prefix = "eleven:"

    /// The ElevenLabs voice id inside an area's `voiceID`, or nil for a device voice.
    static func parse(_ voiceID: String?) -> String? {
        guard let voiceID, voiceID.hasPrefix(prefix) else { return nil }
        let id = voiceID.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// "eleven:<id>", as stored in `CueCallArea.voiceID`.
    static func tag(_ elevenID: String) -> String { prefix + elevenID }

    static func isEleven(_ voiceID: String?) -> Bool { parse(voiceID) != nil }
}

// MARK: - API key

/// The API key lives in the Keychain (this device only), never in UserDefaults or source.
/// DEBUG builds also read `ELEVENLABS_API_KEY` from the environment or `-elevenKey <key>` from
/// the launch arguments, for testing.
enum ElevenLabsKeychain {
    static let service = "com.pixelhaus.tcplayback.elevenlabs"
    static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, let data = k.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func remove() { SecItemDelete(query as CFDictionary) }

    /// DEBUG only: a key from the environment or launch arguments.
    static var debugKey: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-elevenKey"), i + 1 < args.count, !args[i + 1].isEmpty { return args[i + 1] }
        if let e = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !e.isEmpty { return e }
        #endif
        return nil
    }

    /// The key requests use: the Keychain's, else (DEBUG) the testing key.
    static func currentKey() -> String? { read() ?? debugKey }
}

// MARK: - Preferences

struct ElevenLabsVoiceSettings: Codable, Hashable, Sendable {
    var stability = 0.5
    var similarityBoost = 0.75
    var style = 0.0
    var useSpeakerBoost = true
}

enum ElevenLabsModel: String, CaseIterable, Identifiable, Sendable {
    /// Best quality; the default.
    case multilingualV2 = "eleven_multilingual_v2"
    /// Much faster and cheaper; reads numbers less reliably.
    case flashV2_5 = "eleven_flash_v2_5"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .multilingualV2: "Multilingual v2 (most natural)"
        case .flashV2_5: "Flash v2.5 (faster)"
        }
    }
    /// The API ignores (multilingual v2) or honours `language_code`; only send it where it counts.
    var acceptsLanguageCode: Bool { self != .multilingualV2 }
}

struct ElevenLabsPreferences: Codable, Equatable, Sendable {
    static let key = "cueCaller.eleven.preferences"
    var model: String = ElevenLabsModel.multilingualV2.rawValue
    var voice = ElevenLabsVoiceSettings()

    static func load(_ d: UserDefaults = .standard) -> ElevenLabsPreferences {
        guard let data = d.data(forKey: key), let p = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return p
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

// MARK: - Errors

enum ElevenLabsError: LocalizedError, Equatable {
    case noKey
    case unauthorized
    case quotaExceeded
    case rateLimited
    case offline
    case voiceNotFound
    case server(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey: "No ElevenLabs key on this iPad."
        case .unauthorized: "ElevenLabs didn’t accept the key. Check it and enter it again."
        case .quotaExceeded: "This month’s ElevenLabs characters are used up."
        case .rateLimited: "ElevenLabs is busy. Try again in a moment."
        case .offline: "No network connection."
        case .voiceNotFound: "That voice isn’t in the ElevenLabs account."
        case .server(let code, let msg): msg.isEmpty ? "ElevenLabs error \(code)." : "ElevenLabs: \(msg)"
        case .badResponse: "ElevenLabs sent something unexpected."
        }
    }

    /// Maps an HTTP failure. ElevenLabs reports quota as 401 with `detail.status = quota_exceeded`
    /// (and plan limits sometimes as 402/429), so the body is read, not just the status code.
    static func from(status: Int, body: Data) -> ElevenLabsError {
        let (code, message) = detail(body)
        let c = code.lowercased()
        if c.contains("quota") || c.contains("credits") || status == 402 { return .quotaExceeded }
        switch status {
        case 401, 403: return .unauthorized
        case 404 where c.contains("voice") || message.lowercased().contains("voice"): return .voiceNotFound
        case 429: return .rateLimited
        default: return .server(status, message)
        }
    }

    static func from(_ error: Error) -> Error {
        if let e = error as? ElevenLabsError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .timedOut, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return ElevenLabsError.offline
            default: break
            }
        }
        return error
    }

    /// (status code, message) from `{"detail": {"status": …, "message": …}}` or `{"detail": "…"}`.
    private static func detail(_ body: Data) -> (String, String) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return ("", "") }
        if let d = obj["detail"] as? [String: Any] {
            return ((d["status"] as? String) ?? (d["code"] as? String) ?? "", (d["message"] as? String) ?? "")
        }
        if let d = obj["detail"] as? String { return ("", d) }
        if let list = obj["detail"] as? [[String: Any]], let m = list.first?["msg"] as? String { return ("", m) }
        return ("", "")
    }
}

// MARK: - Wire types

struct ElevenLabsSubscription: Decodable, Equatable, Sendable {
    var characterCount: Int
    var characterLimit: Int
    var tier: String?
    var nextCharacterCountResetUnix: Int?
    var charactersLeft: Int { max(0, characterLimit - characterCount) }

    enum CodingKeys: String, CodingKey {
        case characterCount = "character_count", characterLimit = "character_limit", tier
        case nextCharacterCountResetUnix = "next_character_count_reset_unix"
    }
}

/// A voice in the user's account (GET /v2/voices).
struct ElevenLabsVoice: Decodable, Identifiable, Hashable, Sendable {
    var voiceID: String
    var name: String
    var category: String?
    var description: String?
    var previewURL: String?
    var labels: [String: String]?
    var id: String { voiceID }
    var accent: String? { labels?["accent"] }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id", name, category, description, labels
        case previewURL = "preview_url"
    }
}

/// A voice in the shared library (GET /v1/shared-voices).
struct ElevenLabsSharedVoice: Decodable, Identifiable, Hashable, Sendable {
    var publicOwnerID: String
    var voiceID: String
    var name: String
    var accent: String?
    var gender: String?
    var age: String?
    var language: String?
    var locale: String?
    var description: String?
    var previewURL: String?
    var useCase: String?
    var usage1y: Int?
    var clonedBy: Int?
    var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case publicOwnerID = "public_owner_id", voiceID = "voice_id", name, accent, gender, age, language, locale, description
        case previewURL = "preview_url", useCase = "use_case", usage1y = "usage_character_count_1y", clonedBy = "cloned_by_count"
    }
}

/// What to search the shared library for, per area language.
struct ElevenLabsSharedVoiceQuery: Hashable, Sendable {
    var language: String       // ISO 639-1, "de"
    var locale: String?        // "de-CH"
    var accent: String?        // "swiss"
    var gender: String?        // "female" / "male"
    var pageSize = 40

    /// The search for an area language: Swiss accent for de-CH, Swedish for sv-SE, and so on.
    static func forArea(language tag: String, gender: String? = nil) -> ElevenLabsSharedVoiceQuery {
        let t = tag.replacingOccurrences(of: "_", with: "-")
        let code = CueCallLanguage.code(t)
        let region = Locale.Language(identifier: t).region?.identifier
        let accents: [String: String] = [
            "en-US": "american", "en-GB": "british", "fr-FR": "parisian", "es-ES": "peninsular",
            "es-MX": "mexican", "de-DE": "standard", "de-CH": "swiss", "sv-SE": "swedish",
        ]
        let locale = region.map { "\(code)-\($0)" }
        return .init(language: code, locale: locale, accent: locale.flatMap { accents[$0] }, gender: gender)
    }
}

struct ElevenLabsAlignment: Codable, Hashable, Sendable {
    var characters: [String]
    var starts: [Double]
    var ends: [Double]

    enum CodingKeys: String, CodingKey {
        case characters, starts = "character_start_times_seconds", ends = "character_end_times_seconds"
    }

    /// Seconds into the audio where the last occurrence of `word` starts (case- and
    /// accent-insensitive). Falls back to the start of the last word in the text.
    func start(ofLast word: String) -> Double? {
        guard !characters.isEmpty, starts.count == characters.count else { return nil }
        let joined = characters.joined()
        // Element index for each Character offset in `joined`.
        var owner: [Int] = []
        for (i, c) in characters.enumerated() { owner += Array(repeating: i, count: max(1, c.count)) }
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty, let r = joined.range(of: w, options: [.backwards, .caseInsensitive, .diacriticInsensitive]) {
            let off = joined.distance(from: joined.startIndex, to: r.lowerBound)
            if off < owner.count { return starts[owner[off]] }
        }
        // Last run of letters/digits.
        var i = characters.count - 1
        func isWord(_ s: String) -> Bool { s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        while i >= 0, !isWord(characters[i]) { i -= 1 }
        guard i >= 0 else { return nil }
        while i > 0, isWord(characters[i - 1]) { i -= 1 }
        return starts[i]
    }
}

/// One rendered call as ElevenLabs sent it: mono PCM at 24 kHz plus the alignment.
struct ElevenLabsSpeech: Sendable {
    var pcm: [Float]
    var sampleRate: Double = ElevenLabsSpeechRequest.outputSampleRate
    var alignment: ElevenLabsAlignment?
}

struct ElevenLabsSpeechRequest: Hashable, Sendable {
    static let outputFormat = "pcm_24000"
    static let outputSampleRate: Double = 24_000

    var text: String
    var voiceID: String
    var model: String
    var voice: ElevenLabsVoiceSettings
    var speed: Double
    /// ISO 639-1; only sent to models that use it.
    var languageCode: String?

    /// Disk cache key: everything that changes the audio (text, voice, model, voice settings,
    /// rate and the sample rate the API renders at).
    var cacheKey: String {
        let s = ["v1", text, voiceID, model, String(format: "%.3f", voice.stability), String(format: "%.3f", voice.similarityBoost),
                 String(format: "%.3f", voice.style), voice.useSpeakerBoost ? "1" : "0", String(format: "%.3f", speed),
                 languageCode ?? "", String(Int(Self.outputSampleRate))].joined(separator: "\u{1}")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var body: [String: Any] {
        var b: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": [
                "stability": voice.stability,
                "similarity_boost": voice.similarityBoost,
                "style": voice.style,
                "use_speaker_boost": voice.useSpeakerBoost,
                "speed": speed,
            ] as [String: Any],
        ]
        if let languageCode { b["language_code"] = languageCode }
        return b
    }
}

// MARK: - Client

/// Thin HTTP client. Every request carries `xi-api-key`.
struct ElevenLabsClient: Sendable {
    var base = URL(string: "https://api.elevenlabs.io")!
    var session: URLSession = .shared
    var key: @Sendable () -> String? = { ElevenLabsKeychain.currentKey() }
    var timeout: TimeInterval = 20

    static let shared = ElevenLabsClient()

    func speechURLRequest(_ r: ElevenLabsSpeechRequest, key: String) throws -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent("v1/text-to-speech/\(r.voiceID)/with-timestamps"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "output_format", value: ElevenLabsSpeechRequest.outputFormat)]
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: r.body, options: [.sortedKeys])
        return req
    }

    /// POST /v1/text-to-speech/{voice_id}/with-timestamps?output_format=pcm_24000.
    func speech(_ r: ElevenLabsSpeechRequest) async throws -> (speech: ElevenLabsSpeech, raw: Data) {
        guard let k = key() else { throw ElevenLabsError.noKey }
        let data = try await send(try speechURLRequest(r, key: k))
        struct Reply: Decodable {
            var audio_base64: String
            var alignment: ElevenLabsAlignment?
            var normalized_alignment: ElevenLabsAlignment?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let raw = Data(base64Encoded: reply.audio_base64), raw.count >= 2 else { throw ElevenLabsError.badResponse }
        return (ElevenLabsSpeech(pcm: Self.decodePCM16(raw), alignment: reply.alignment ?? reply.normalized_alignment), raw)
    }

    /// GET /v1/user/subscription.
    func subscription() async throws -> ElevenLabsSubscription {
        let data = try await get("v1/user/subscription", [])
        guard let s = try? JSONDecoder().decode(ElevenLabsSubscription.self, from: data) else { throw ElevenLabsError.badResponse }
        return s
    }

    /// GET /v2/voices (all pages, up to 300 voices).
    func accountVoices() async throws -> [ElevenLabsVoice] {
        struct Page: Decodable { var voices: [ElevenLabsVoice]; var has_more: Bool?; var next_page_token: String? }
        var out: [ElevenLabsVoice] = []
        var token: String?
        for _ in 0..<3 {
            var q = [URLQueryItem(name: "page_size", value: "100")]
            if let token { q.append(URLQueryItem(name: "next_page_token", value: token)) }
            let data = try await get("v2/voices", q)
            guard let p = try? JSONDecoder().decode(Page.self, from: data) else { throw ElevenLabsError.badResponse }
            out += p.voices
            guard p.has_more == true, let t = p.next_page_token else { break }
            token = t
        }
        return out
    }

    /// GET /v1/shared-voices, most used first. Narrows by locale, then accent, then language
    /// alone until it finds enough voices.
    func sharedVoices(_ q: ElevenLabsSharedVoiceQuery) async throws -> [ElevenLabsSharedVoice] {
        struct Page: Decodable { var voices: [ElevenLabsSharedVoice] }
        func fetch(locale: String?, accent: String?) async throws -> [ElevenLabsSharedVoice] {
            var items = [URLQueryItem(name: "page_size", value: String(q.pageSize)),
                         URLQueryItem(name: "language", value: q.language),
                         URLQueryItem(name: "sort", value: "usage_character_count_1y")]
            if let locale { items.append(URLQueryItem(name: "locale", value: locale)) }
            if let accent { items.append(URLQueryItem(name: "accent", value: accent)) }
            if let g = q.gender { items.append(URLQueryItem(name: "gender", value: g)) }
            let data = try await get("v1/shared-voices", items)
            guard let p = try? JSONDecoder().decode(Page.self, from: data) else { throw ElevenLabsError.badResponse }
            return p.voices
        }
        var seen = Set<String>(), out: [ElevenLabsSharedVoice] = []
        let passes: [(String?, String?)] = [(q.locale, nil), (nil, q.accent), (nil, nil)]
        for (i, pass) in passes.enumerated() {
            if i > 0 && pass.0 == nil && pass.1 == nil && out.count >= 8 { break }
            if i == 1 && q.accent == nil { continue }
            if i == 0 && q.locale == nil { continue }
            for v in try await fetch(locale: pass.0, accent: pass.1) where seen.insert(v.voiceID).inserted { out.append(v) }
        }
        return out.sorted { ($0.usage1y ?? 0) > ($1.usage1y ?? 0) }
    }

    /// POST /v1/voices/add/{public_owner_id}/{voice_id} with `new_name`. Returns the voice id.
    func addSharedVoice(publicOwnerID: String, voiceID: String, name: String) async throws -> String {
        guard let k = key() else { throw ElevenLabsError.noKey }
        var req = URLRequest(url: base.appendingPathComponent("v1/voices/add/\(publicOwnerID)/\(voiceID)"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(k, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["new_name": name])
        let data = try await send(req)
        struct Reply: Decodable { var voice_id: String }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.voice_id ?? voiceID
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        guard let k = key() else { throw ElevenLabsError.noKey }
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { c.queryItems = items }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.setValue(k, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw ElevenLabsError.from(error) }
        guard let http = resp as? HTTPURLResponse else { throw ElevenLabsError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ElevenLabsError.from(status: http.statusCode, body: data) }
        return data
    }

    /// 16-bit little-endian mono PCM → float.
    static func decodePCM16(_ data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lo = UInt16(p[2 * i]), hi = UInt16(p[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }
}

// MARK: - Disk cache

/// Rendered calls on disk (Application Support/CueCaller/Voices), as ElevenLabs sent them: the
/// raw PCM and its alignment. Processing for the output rate happens on load, so a show prepared
/// at one sample rate still plays from cache on an interface at another. Survives relaunch.
final class ElevenLabsCallCache: @unchecked Sendable {
    static let shared = ElevenLabsCallCache(directory: ElevenLabsCallCache.defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CueCaller", isDirectory: true).appendingPathComponent("Voices", isDirectory: true)
    }

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private struct Meta: Codable { var text: String; var voiceID: String; var model: String; var sampleRate: Double; var alignment: ElevenLabsAlignment? }

    private func pcmURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".pcm") }
    private func metaURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: pcmURL(key).path) && FileManager.default.fileExists(atPath: metaURL(key).path)
    }

    func load(_ key: String) -> ElevenLabsSpeech? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: pcmURL(key)), raw.count >= 2,
              let md = try? Data(contentsOf: metaURL(key)), let meta = try? JSONDecoder().decode(Meta.self, from: md) else { return nil }
        return ElevenLabsSpeech(pcm: ElevenLabsClient.decodePCM16(raw), sampleRate: meta.sampleRate, alignment: meta.alignment)
    }

    func store(raw: Data, alignment: ElevenLabsAlignment?, for r: ElevenLabsSpeechRequest) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = r.cacheKey
        let meta = Meta(text: r.text, voiceID: r.voiceID, model: r.model, sampleRate: ElevenLabsSpeechRequest.outputSampleRate, alignment: alignment)
        guard let md = try? JSONEncoder().encode(meta) else { return }
        try? raw.write(to: pcmURL(key), options: .atomic)
        try? md.write(to: metaURL(key), options: .atomic)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Bytes used on disk.
    var size: Int {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Renderer

/// Renders calls with ElevenLabs: disk cache first, then the network.
final class ElevenLabsCueCallRenderer: @unchecked Sendable {
    static let shared = ElevenLabsCueCallRenderer()

    let client: ElevenLabsClient
    let cache: ElevenLabsCallCache
    let preferences: @Sendable () -> ElevenLabsPreferences
    var targetLUFS: Double = -16
    var peakCeilingDBFS: Float = -1.5

    init(client: ElevenLabsClient = .shared, cache: ElevenLabsCallCache = .shared,
         preferences: @escaping @Sendable () -> ElevenLabsPreferences = { ElevenLabsPreferences.load() }) {
        self.client = client
        self.cache = cache
        self.preferences = preferences
    }

    /// Area rate (AVSpeech scale, 0.5 = normal) → ElevenLabs `speed` (0.7…1.2, 1 = normal).
    static func speed(forRate rate: Float) -> Double {
        let s = Double(min(max(rate, 0.3), 0.65)) / 0.5
        return (min(max(s, 0.7), 1.2) * 100).rounded() / 100
    }

    /// The request for a line. `text` is the full spoken line in the area's language.
    func request(text: String, language: String, voiceID: String, rate: Float) -> ElevenLabsSpeechRequest {
        let p = preferences()
        let model = ElevenLabsModel(rawValue: p.model)
        return ElevenLabsSpeechRequest(text: CueCallLexicon.speakable(text, language: language), voiceID: voiceID, model: p.model,
                                       voice: p.voice, speed: Self.speed(forRate: rate),
                                       languageCode: (model?.acceptsLanguageCode ?? true) ? CueCallLanguage.code(language) : nil)
    }

    /// Already on disk (plays with no network).
    func isReady(_ r: ElevenLabsSpeechRequest) -> Bool { cache.contains(r.cacheKey) }

    /// Cached speech, else fetch and cache it.
    func speech(for r: ElevenLabsSpeechRequest) async throws -> ElevenLabsSpeech {
        if let hit = cache.load(r.cacheKey) { return hit }
        let (s, raw) = try await client.speech(r)
        cache.store(raw: raw, alignment: s.alignment, for: r)
        return s
    }

    /// A call, levelled, at `sampleRate`. With `goWord`, `goOnset` is where it starts.
    func render(text: String, goWord: String?, language: String, voiceID: String, rate: Float, sampleRate: Double) async throws -> CueCallAudio {
        let r = request(text: text, language: language, voiceID: voiceID, rate: rate)
        let s = try await speech(for: r)
        return try Self.process(s, goWord: goWord, sampleRate: sampleRate, targetLUFS: targetLUFS, ceilingDBFS: peakCeilingDBFS)
    }

    /// Trim, fade and level exactly like `SpeechCueCallRenderer`, then correct the go onset for
    /// the trimmed lead-in.
    static func process(_ s: ElevenLabsSpeech, goWord: String?, sampleRate: Double,
                        targetLUFS: Double = -16, ceilingDBFS: Float = -1.5) throws -> CueCallAudio {
        guard let bounds = SpeechCueCallRenderer.trimBounds(s.pcm, sampleRate: s.sampleRate) else {
            throw SpeechCueCallRenderer.RenderError.noAudio
        }
        let trimmed = Array(s.pcm[bounds])
        let trimmedDuration = Double(trimmed.count) / s.sampleRate
        let onset: Double? = goWord.flatMap { s.alignment?.start(ofLast: $0) }.map {
            min(max(0, $0 - Double(bounds.lowerBound) / s.sampleRate), trimmedDuration)
        }
        var out = try SpeechCueCallRenderer.resample(trimmed, from: s.sampleRate, to: sampleRate)
        SpeechCueCallRenderer.fadeEdges(&out, sampleRate: sampleRate)
        CueCallLoudness.level(&out, sampleRate: sampleRate, targetLUFS: targetLUFS, ceilingDBFS: ceilingDBFS)
        return CueCallAudio(samples: out, sampleRate: sampleRate, goOnset: onset)
    }
}

// MARK: - Router

/// Sends each call to the right voice: "eleven:" ids to ElevenLabs (falling back to the device
/// voice when ElevenLabs can't deliver: offline, quota, bad key), everything else to
/// `SpeechCueCallRenderer`. A call always goes out.
final class CueCallVoiceRouter: CueCallVoiceRenderer, @unchecked Sendable {
    static let shared = CueCallVoiceRouter()

    enum Route: Equatable { case eleven(String), device }

    let eleven: ElevenLabsCueCallRenderer
    let device: CueCallRenderStep
    let deviceRenderer: any CueCallVoiceRenderer
    /// Called (any thread) when the set of calls that fell back changes.
    var onFallbacksChanged: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var fallbacks: [String: String] = [:]

    init(eleven: ElevenLabsCueCallRenderer = .shared,
         device: @escaping CueCallRenderStep = CueCallVoiceRouter.speechStep,
         deviceRenderer: any CueCallVoiceRenderer = SpeechCueCallRenderer.shared) {
        self.eleven = eleven
        self.device = device
        self.deviceRenderer = deviceRenderer
    }

    static func route(_ voiceID: String?) -> Route {
        ElevenLabsVoiceID.parse(voiceID).map(Route.eleven) ?? .device
    }

    /// The engine's render step.
    func renderStep() -> CueCallRenderStep {
        { [self] call, note, area, sr in try await self.render(call: call, note: note, area: area, sampleRate: sr) }
    }

    func render(call: CueCall, note: String, area: CueCallArea, sampleRate: Double) async throws -> CueCallRenderedAudio {
        guard case .eleven(let id) = Self.route(area.voiceID) else { return try await device(call, note, area, sampleRate) }
        let key = Self.fallbackKey(call: call, area: area)
        do {
            let goWord = call.kind == .go ? CueCallTemplates.template(for: area.language).goWord : nil
            let a = try await eleven.render(text: call.text, goWord: goWord, language: area.language, voiceID: id,
                                            rate: area.rate, sampleRate: sampleRate)
            setFallback(key, nil)
            return CueCallRenderedAudio(samples: a.samples, goOnset: a.goOnset.map { Int(($0 * sampleRate).rounded()) })
        } catch {
            setFallback(key, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            var onDevice = area
            onDevice.voiceID = nil
            return try await device(call, note, onDevice, sampleRate)
        }
    }

    /// Plain render (no go onset), for `CueCaller.renderer`.
    func render(_ text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> [Float] {
        if case .eleven(let id) = Self.route(voiceID) {
            if let a = try? await eleven.render(text: text, goWord: nil, language: language, voiceID: id, rate: rate, sampleRate: sampleRate) {
                return a.samples
            }
            return try await deviceRenderer.render(text, language: language, voiceID: nil, rate: rate, sampleRate: sampleRate)
        }
        return try await deviceRenderer.render(text, language: language, voiceID: voiceID, rate: rate, sampleRate: sampleRate)
    }

    // MARK: Fallback log

    static func fallbackKey(call: CueCall, area: CueCallArea) -> String { "\(area.id.uuidString)|\(call.kind.rawValue)|\(call.text)" }

    /// Calls that used the device voice instead of ElevenLabs, with the reason.
    var fallbackReasons: [String: String] { lock.lock(); defer { lock.unlock() }; return fallbacks }
    var fallbackCount: Int { fallbackReasons.count }

    func clearFallbacks() {
        lock.lock(); let changed = !fallbacks.isEmpty; fallbacks = [:]; lock.unlock()
        if changed { onFallbacksChanged?() }
    }

    private func setFallback(_ key: String, _ reason: String?) {
        lock.lock()
        let changed = fallbacks[key] != reason
        fallbacks[key] = reason
        lock.unlock()
        if changed { onFallbacksChanged?() }
    }

    /// The device voice (AVSpeechSynthesizer), with the go word placed on its own.
    static let speechStep: CueCallRenderStep = { call, note, area, sampleRate in
        let voice = SpeechCueCallRenderer.shared
        let deviceVoice = ElevenLabsVoiceID.isEleven(area.voiceID) ? nil : area.voiceID
        if call.kind == .go {
            let audio = try await voice.renderGo(note: note, template: CueCallTemplates.template(for: area.language),
                                                 language: area.language, voiceID: deviceVoice,
                                                 rate: area.rate, sampleRate: sampleRate)
            return CueCallRenderedAudio(samples: audio.samples,
                                        goOnset: audio.goOnset.map { Int(($0 * sampleRate).rounded()) })
        }
        let samples = try await voice.render(call.text, language: area.language, voiceID: deviceVoice,
                                             rate: area.rate, sampleRate: sampleRate)
        return CueCallRenderedAudio(samples: samples)
    }
}
