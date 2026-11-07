import Foundation
import Translation
import XCTest
@testable import TCPlayback

/// ElevenLabs voices for the cue caller: request shape, PCM decode, go onset from the alignment,
/// the disk cache, the device-voice fallback and the voice router. No network: every request
/// goes to `MockElevenLabsProtocol`. Nothing is played; audio stays in buffers.
final class ToolsCueCallerElevenLabsTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eleven-\(UUID().uuidString)", isDirectory: true)
        MockElevenLabsProtocol.reset()
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        MockElevenLabsProtocol.reset()
    }

    // MARK: Fixtures

    private func client(key: String? = "test-key") -> ElevenLabsClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockElevenLabsProtocol.self]
        return ElevenLabsClient(session: URLSession(configuration: cfg), key: { key }, timeout: 5)
    }

    private func renderer(_ c: ElevenLabsClient? = nil, model: ElevenLabsModel = .multilingualV2) -> ElevenLabsCueCallRenderer {
        var prefs = ElevenLabsPreferences()
        prefs.model = model.rawValue
        let p = prefs
        return ElevenLabsCueCallRenderer(client: c ?? client(), cache: ElevenLabsCallCache(directory: dir), preferences: { p })
    }

    static func pcm16(_ x: [Float]) -> Data {
        var d = Data(capacity: x.count * 2)
        for v in x {
            let i = Int16(max(-32768, min(32767, (v * 32767).rounded())))
            let u = UInt16(bitPattern: i)
            d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8))
        }
        return d
    }

    /// 24 kHz: `lead` s silence, a 0.5 s tone ("note"), 0.1 s gap, a 0.2 s tone (go word), 0.2 s silence.
    static func speechPCM(lead: Double = 0.3) -> (samples: [Float], goAt: Double) {
        let sr = 24_000.0
        func tone(_ s: Double, _ f: Double) -> [Float] { (0..<Int(s * sr)).map { Float(0.4 * sin(2 * .pi * f * Double($0) / sr)) } }
        func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * sr)) }
        let x = silence(lead) + tone(0.5, 300) + silence(0.1) + tone(0.2, 500) + silence(0.2)
        return (x, lead + 0.6)
    }

    /// A with-timestamps reply for `text`: characters spread evenly up to `goAt`, then the go word.
    static func reply(text: String, goWord: String, goAt: Double, pcm: [Float]) -> Data {
        let chars = text.map(String.init)
        let goStart = text.range(of: goWord, options: .backwards).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? chars.count
        var starts: [Double] = []
        for i in chars.indices {
            if i < goStart { starts.append(0.3 + (goAt - 0.4) * Double(i) / Double(max(1, goStart))) }
            else { starts.append(goAt + 0.05 * Double(i - goStart)) }
        }
        let ends = starts.map { $0 + 0.04 }
        let obj: [String: Any] = [
            "audio_base64": pcm16(pcm).base64EncodedString(),
            "alignment": ["characters": chars, "character_start_times_seconds": starts, "character_end_times_seconds": ends],
            "normalized_alignment": NSNull(),
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func serveSpeech(goWord: String = "go") {
        MockElevenLabsProtocol.handler = { req in
            let body = (try? JSONSerialization.jsonObject(with: MockElevenLabsProtocol.body(of: req))) as? [String: Any]
            let text = body?["text"] as? String ?? ""
            let s = Self.speechPCM()
            return (200, Self.reply(text: text, goWord: goWord, goAt: s.goAt, pcm: s.samples))
        }
    }

    // MARK: Voice ids and routing

    func testElevenVoiceIDParsing() {
        XCTAssertEqual(ElevenLabsVoiceID.parse("eleven:21m00Tcm4TlvDq8ikWAM"), "21m00Tcm4TlvDq8ikWAM")
        XCTAssertEqual(ElevenLabsVoiceID.tag("abc"), "eleven:abc")
        XCTAssertNil(ElevenLabsVoiceID.parse("eleven:"))
        XCTAssertNil(ElevenLabsVoiceID.parse("eleven:  "))
        XCTAssertNil(ElevenLabsVoiceID.parse("com.apple.voice.premium.de-DE.Anna"))
        XCTAssertNil(ElevenLabsVoiceID.parse(nil))
        XCTAssertNil(ElevenLabsVoiceID.parse("Eleven:abc"), "prefix is exact")
        XCTAssertTrue(ElevenLabsVoiceID.isEleven("eleven:x"))
    }

    func testRouterPicksElevenLabsOrDeviceVoice() async throws {
        XCTAssertEqual(CueCallVoiceRouter.route("eleven:abc"), .eleven("abc"))
        XCTAssertEqual(CueCallVoiceRouter.route("com.apple.voice.enhanced.en-US.Zoe"), .device)
        XCTAssertEqual(CueCallVoiceRouter.route(nil), .device)

        serveSpeech()
        let deviceCalls = Counter()
        let stub = StubCueCallRenderer().renderStep()
        let router = CueCallVoiceRouter(eleven: renderer(), device: { c, n, a, sr in
            deviceCalls.bump(a.voiceID ?? "nil")
            return try await stub(c, n, a, sr)
        }, deviceRenderer: StubCueCallRenderer())

        let call = CueCall(markID: UUID(), areaID: UUID(), kind: .go, at: 10, text: "Camera 3, push in… go.")
        let eleven = CueCallArea(name: "Cams", language: "en-US", voiceID: "eleven:VOICE1")
        let a = try await router.render(call: call, note: "Camera 3, push in", area: eleven, sampleRate: 48_000)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 1)
        XCTAssertEqual(deviceCalls.values, [])
        XCTAssertNotNil(a.goOnset)

        let device = CueCallArea(name: "LX", language: "en-GB", voiceID: "com.apple.voice.enhanced.en-GB.Daniel")
        _ = try await router.render(call: call, note: "Camera 3, push in", area: device, sampleRate: 48_000)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 1, "device voices never hit the network")
        XCTAssertEqual(deviceCalls.values, ["com.apple.voice.enhanced.en-GB.Daniel"])
        XCTAssertEqual(router.fallbackCount, 0)
    }

    // MARK: Request shape

    func testSpeechRequestShape() async throws {
        serveSpeech()
        let r = renderer()
        _ = try await r.render(text: "Camera 3, push in… go.", goWord: "go", language: "en-US", voiceID: "VOICE1", rate: 0.5, sampleRate: 48_000)
        let req = try XCTUnwrap(MockElevenLabsProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(req.url?.path, "/v1/text-to-speech/VOICE1/with-timestamps")
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "output_format" }?.value, "pcm_24000")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockElevenLabsProtocol.body(of: req)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Camera 3, push in… go.")
        XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")
        XCTAssertNil(body["language_code"], "multilingual v2 doesn't take language_code")
        let vs = try XCTUnwrap(body["voice_settings"] as? [String: Any])
        XCTAssertEqual(vs["stability"] as? Double, 0.5)
        XCTAssertEqual(vs["similarity_boost"] as? Double, 0.75)
        XCTAssertEqual(vs["style"] as? Double, 0)
        XCTAssertEqual(vs["use_speaker_boost"] as? Bool, true)
        XCTAssertEqual(vs["speed"] as? Double, 1.0)

        // Flash takes the language code; de-CH is sent as German; crew shorthand is respelled.
        MockElevenLabsProtocol.reset(); serveSpeech(goWord: "los")
        let flash = renderer(model: .flashV2_5)
        _ = try await flash.render(text: "LX 4… los.", goWord: "los", language: "de-CH", voiceID: "V2", rate: 0.65, sampleRate: 48_000)
        let b2 = try XCTUnwrap(JSONSerialization.jsonObject(with: MockElevenLabsProtocol.body(of: MockElevenLabsProtocol.requests[0])) as? [String: Any])
        XCTAssertEqual(b2["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(b2["language_code"] as? String, "de")
        XCTAssertEqual(b2["text"] as? String, "L X 4… los.")
        XCTAssertEqual((b2["voice_settings"] as? [String: Any])?["speed"] as? Double, 1.2)
    }

    func testRateMapsToElevenLabsSpeedRange() {
        XCTAssertEqual(ElevenLabsCueCallRenderer.speed(forRate: 0.5), 1.0)
        XCTAssertEqual(ElevenLabsCueCallRenderer.speed(forRate: 0.52), 1.04)
        XCTAssertEqual(ElevenLabsCueCallRenderer.speed(forRate: 0.3), 0.7)
        XCTAssertEqual(ElevenLabsCueCallRenderer.speed(forRate: 0.9), 1.2)
    }

    // MARK: PCM

    func testPCMDecodeAndResample() throws {
        var d = Data()
        for v: Int16 in [0, 16384, -32768, 32767, -1] {
            let u = UInt16(bitPattern: v); d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8))
        }
        d.append(0x7f) // odd trailing byte is ignored
        let f = ElevenLabsClient.decodePCM16(d)
        XCTAssertEqual(f.count, 5)
        XCTAssertEqual(f[0], 0)
        XCTAssertEqual(f[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(f[2], -1, accuracy: 1e-6)
        XCTAssertEqual(f[3], 32767 / 32768, accuracy: 1e-6)
        XCTAssertEqual(f[4], -1 / 32768, accuracy: 1e-7)

        // Processed to 48 kHz: about twice the samples of the trimmed 24 kHz audio, levelled.
        let s = Self.speechPCM()
        let speech = ElevenLabsSpeech(pcm: ElevenLabsClient.decodePCM16(Self.pcm16(s.samples)))
        let trimmed = SpeechCueCallRenderer.trimSilence(speech.pcm, sampleRate: 24_000)
        let a = try ElevenLabsCueCallRenderer.process(speech, goWord: nil, sampleRate: 48_000)
        XCTAssertEqual(a.sampleRate, 48_000)
        XCTAssertEqual(Double(a.samples.count), Double(trimmed.count) * 2, accuracy: 64)
        XCTAssertEqual(CueCallLoudness.integrated(a.samples, sampleRate: 48_000), -16, accuracy: 0.6)
        XCTAssertLessThanOrEqual(a.samples.map(abs).max() ?? 0, powf(10, -1.5 / 20) + 1e-4)
        XCTAssertNil(a.goOnset)
    }

    // MARK: Go onset

    func testGoOnsetFromAlignmentCorrectedForTrim() async throws {
        serveSpeech()
        let r = renderer()
        let a = try await r.render(text: "Camera 3, push in… go.", goWord: "go", language: "en-US", voiceID: "V", rate: 0.5, sampleRate: 48_000)
        // The go word starts at 0.9 s in the raw audio; trimming cut 0.3 s minus the 8 ms lead-in.
        let expected = Self.speechPCM().goAt - (0.3 - 0.008)
        let onset = try XCTUnwrap(a.goOnset)
        XCTAssertEqual(onset, expected, accuracy: 0.002)
        // And the audio really has the go word there: the 500 Hz burst starts within a few ms.
        let i = Int(onset * 48_000)
        let before = a.samples[max(0, i - 2400)..<max(0, i - 480)].map(abs).max() ?? 0
        let after = a.samples[(i + 240)..<(i + 2400)].map(abs).max() ?? 0
        XCTAssertLessThan(before, 0.01, "gap before the go word")
        XCTAssertGreaterThan(after, 0.1, "go word after the onset")

        // Through the router the onset is in samples at the output rate.
        let router = CueCallVoiceRouter(eleven: r, device: StubCueCallRenderer().renderStep(), deviceRenderer: StubCueCallRenderer())
        let call = CueCall(markID: UUID(), areaID: UUID(), kind: .go, at: 5, text: "Camera 3, push in… go.")
        let ra = try await router.render(call: call, note: "Camera 3, push in",
                                         area: CueCallArea(name: "C", language: "en-US", voiceID: "eleven:V"), sampleRate: 48_000)
        XCTAssertEqual(Double(try XCTUnwrap(ra.goOnset)), expected * 48_000, accuracy: 100)
    }

    func testAlignmentFindsLastGoWord() {
        func al(_ s: String) -> ElevenLabsAlignment {
            let c = s.map(String.init)
            return ElevenLabsAlignment(characters: c, starts: c.indices.map { Double($0) / 10 }, ends: c.indices.map { Double($0) / 10 + 0.1 })
        }
        // "go" inside "Go to cam 2… go." — the last one.
        let a = al("Go to cam 2… go.")
        XCTAssertEqual(a.start(ofLast: "go") ?? -1, 1.3, accuracy: 1e-9)
        // Swedish, accent-insensitive.
        let sv = al("Kamera 3, zooma in… kör.")
        XCTAssertEqual(sv.start(ofLast: "kör") ?? -1, Double(Array("Kamera 3, zooma in… ").count) / 10, accuracy: 1e-9)
        XCTAssertEqual(sv.start(ofLast: "kor") ?? -1, sv.start(ofLast: "kör") ?? -2, accuracy: 1e-9)
        // Word missing (normalised away): the start of the last word.
        let fr = al("Caméra 2… top.")
        XCTAssertEqual(fr.start(ofLast: "ya") ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertNil(ElevenLabsAlignment(characters: [], starts: [], ends: []).start(ofLast: "go"))
    }

    // MARK: Disk cache

    func testDiskCacheHitAfterRelaunch() async throws {
        serveSpeech()
        let first = renderer()
        let req = first.request(text: "Standby, camera 3.", language: "en-US", voiceID: "V", rate: 0.52)
        XCTAssertFalse(first.isReady(req))
        let a1 = try await first.render(text: "Standby, camera 3.", goWord: nil, language: "en-US", voiceID: "V", rate: 0.52, sampleRate: 48_000)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(req.cacheKey + ".pcm").path))

        // "Relaunch": a fresh cache and renderer on the same folder, and no network at all.
        MockElevenLabsProtocol.reset()
        MockElevenLabsProtocol.failure = URLError(.notConnectedToInternet)
        let again = renderer()
        XCTAssertTrue(again.isReady(req))
        let a2 = try await again.render(text: "Standby, camera 3.", goWord: nil, language: "en-US", voiceID: "V", rate: 0.52, sampleRate: 48_000)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 0)
        XCTAssertEqual(a1.samples, a2.samples)
        // A different rate in the show (44.1 kHz interface) still comes from the cache.
        let a3 = try await again.render(text: "Standby, camera 3.", goWord: nil, language: "en-US", voiceID: "V", rate: 0.52, sampleRate: 44_100)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 0)
        XCTAssertEqual(Double(a3.samples.count), Double(a1.samples.count) * 44_100 / 48_000, accuracy: 64)
    }

    func testCacheKeyCoversEverythingThatChangesTheAudio() {
        let base = ElevenLabsSpeechRequest(text: "Go.", voiceID: "V", model: "eleven_multilingual_v2", voice: .init(), speed: 1, languageCode: nil)
        var keys = Set([base.cacheKey])
        var r = base; r.text = "Los."; keys.insert(r.cacheKey)
        r = base; r.voiceID = "W"; keys.insert(r.cacheKey)
        r = base; r.model = "eleven_flash_v2_5"; keys.insert(r.cacheKey)
        r = base; r.voice.stability = 0.6; keys.insert(r.cacheKey)
        r = base; r.voice.similarityBoost = 0.8; keys.insert(r.cacheKey)
        r = base; r.speed = 1.1; keys.insert(r.cacheKey)
        r = base; r.languageCode = "de"; keys.insert(r.cacheKey)
        XCTAssertEqual(keys.count, 8)
        XCTAssertEqual(base.cacheKey, ElevenLabsSpeechRequest(text: "Go.", voiceID: "V", model: "eleven_multilingual_v2", voice: .init(), speed: 1, languageCode: nil).cacheKey)
    }

    // MARK: Failures and fallback

    func testFallsBackToDeviceVoiceWhenElevenLabsFails() async throws {
        let device = Counter()
        let stub = StubCueCallRenderer().renderStep()
        func router() -> CueCallVoiceRouter {
            CueCallVoiceRouter(eleven: renderer(), device: { c, n, a, sr in
                device.bump(a.voiceID ?? "best")
                return try await stub(c, n, a, sr)
            }, deviceRenderer: StubCueCallRenderer())
        }
        let area = CueCallArea(name: "Cams", language: "sv-SE", voiceID: "eleven:V")
        let call = CueCall(markID: UUID(), areaID: area.id, kind: .go, at: 3, text: "Kamera 3… kör.")

        // Offline.
        MockElevenLabsProtocol.failure = URLError(.notConnectedToInternet)
        let r1 = router()
        let changed = Counter()
        r1.onFallbacksChanged = { changed.bump("x") }
        let a = try await r1.render(call: call, note: "Kamera 3", area: area, sampleRate: 48_000)
        XCTAssertFalse(a.samples.isEmpty, "a call always goes out")
        XCTAssertEqual(device.values, ["best"], "falls back to the best device voice for the language")
        XCTAssertEqual(r1.fallbackCount, 1)
        XCTAssertEqual(r1.fallbackReasons.values.first, ElevenLabsError.offline.errorDescription)
        XCTAssertEqual(changed.values.count, 1)

        // Back online: the same call clears its fallback.
        MockElevenLabsProtocol.reset(); serveSpeech(goWord: "kör")
        _ = try await r1.render(call: call, note: "Kamera 3", area: area, sampleRate: 48_000)
        XCTAssertEqual(r1.fallbackCount, 0)
        XCTAssertEqual(device.values.count, 1)

        // Quota used up (401 quota_exceeded) also falls back.
        MockElevenLabsProtocol.reset()
        MockElevenLabsProtocol.handler = { _ in (401, Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}"#.utf8)) }
        let r2 = router()
        let other = CueCall(markID: UUID(), areaID: area.id, kind: .standby, at: 0, text: "Stand by, kamera 4.")
        _ = try await r2.render(call: other, note: "kamera 4", area: area, sampleRate: 48_000)
        XCTAssertEqual(r2.fallbackReasons.values.first, ElevenLabsError.quotaExceeded.errorDescription)

        // No key: device voice, no request.
        MockElevenLabsProtocol.reset()
        let noKey = CueCallVoiceRouter(eleven: renderer(client(key: nil)), device: stub, deviceRenderer: StubCueCallRenderer())
        _ = try await noKey.render(call: other, note: "kamera 4", area: area, sampleRate: 48_000)
        XCTAssertEqual(MockElevenLabsProtocol.requests.count, 0)
        XCTAssertEqual(noKey.fallbackCount, 1)
    }

    func testErrorMapping() {
        func body(_ s: String) -> Data { Data(s.utf8) }
        XCTAssertEqual(ElevenLabsError.from(status: 401, body: body(#"{"detail":{"status":"quota_exceeded","message":"x"}}"#)), .quotaExceeded)
        XCTAssertEqual(ElevenLabsError.from(status: 401, body: body(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#)), .unauthorized)
        XCTAssertEqual(ElevenLabsError.from(status: 429, body: body(#"{"detail":{"status":"too_many_concurrent_requests"}}"#)), .rateLimited)
        XCTAssertEqual(ElevenLabsError.from(status: 402, body: Data()), .quotaExceeded)
        XCTAssertEqual(ElevenLabsError.from(status: 402, body: body(#"{"detail":{"type":"payment_required","code":"paid_plan_required","message":"Free users cannot use library voices via the API.","status":"payment_required"}}"#)), .paidPlanRequired)
        XCTAssertEqual(ElevenLabsError.from(status: 500, body: body(#"{"detail":"Server error"}"#)), .server(500, "Server error"))
        XCTAssertEqual(ElevenLabsError.from(URLError(.timedOut)) as? ElevenLabsError, .offline)
        XCTAssertEqual(ElevenLabsError.from(URLError(.notConnectedToInternet)) as? ElevenLabsError, .offline)
    }

    func testSubscriptionAndSharedVoices() async throws {
        MockElevenLabsProtocol.handler = { req in
            switch req.url?.path {
            case "/v1/user/subscription":
                return (200, Data(#"{"character_count":15790,"character_limit":100000,"tier":"creator","status":"active"}"#.utf8))
            case "/v1/shared-voices":
                let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let id = q.contains { $0.name == "locale" } ? "loc" : (q.contains { $0.name == "accent" } ? "acc" : "lang")
                return (200, Data(#"{"voices":[{"public_owner_id":"o","voice_id":"\#(id)","name":"N \#(id)","accent":"swiss","gender":"female","age":"young","descriptive":"calm","use_case":"x","category":"professional","language":"de","locale":"de-CH","usage_character_count_1y":\#(id == "acc" ? 900 : id == "loc" ? 10 : 5),"cloned_by_count":1}],"has_more":false}"#.utf8))
            default: return (404, Data())
            }
        }
        let c = client()
        let s = try await c.subscription()
        XCTAssertEqual(s.charactersLeft, 84_210)
        XCTAssertEqual(CueCallVoicesModel.Connection.connected(charactersLeft: s.charactersLeft).label,
                       "Connected · \(84_210.formatted(.number)) characters left this month")

        let q = ElevenLabsSharedVoiceQuery.forArea(language: "de-CH", gender: "female")
        XCTAssertEqual(q.language, "de"); XCTAssertEqual(q.locale, "de-CH"); XCTAssertEqual(q.accent, "swiss")
        XCTAssertEqual(ElevenLabsSharedVoiceQuery.forArea(language: "sv-SE").accent, "swedish")
        let v = try await c.sharedVoices(q)
        XCTAssertEqual(v.map(\.voiceID), ["acc", "loc", "lang"], "deduped, most used first")
        let first = try XCTUnwrap(MockElevenLabsProtocol.requests.first { $0.url?.path == "/v1/shared-voices" })
        let items = URLComponents(url: first.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "de")
        XCTAssertEqual(items.first { $0.name == "gender" }?.value, "female")
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "usage_character_count_1y")
        XCTAssertEqual(first.value(forHTTPHeaderField: "xi-api-key"), "test-key")
    }

    // MARK: Languages

    func testSwedishTemplateHasGoWordLast() {
        let sv = CueCallTemplates.template(for: "sv-SE")
        XCTAssertEqual(sv.language, "sv")
        XCTAssertEqual(sv.goWord, "kör")
        XCTAssertTrue(sv.goWordIsLast)
        XCTAssertEqual(sv.goText("Kamera 3, zooma in"), "Kamera 3, zooma in… kör")
        XCTAssertEqual(sv.standbyText("kamera 3"), "Stand by, kamera 3")
        XCTAssertEqual(sv.goParts("Kamera 3").goWord, "kör")
        XCTAssertEqual(CueCallLexicon.speakable("Cam 2", language: "sv-SE"), "Kamera 2")
    }

    func testSwissGermanUsesGermanTemplateAndTranslatesAsGerman() {
        XCTAssertEqual(CueCallTemplates.template(for: "de-CH").goWord, "los")
        XCTAssertEqual(CueCallLanguage.translationTag("de-CH"), "de")
        XCTAssertTrue(CueCallLanguage.same("de-CH", "de-DE"))
        let ids = CueCallerUIModel.commonLanguages.prefix(7).map(\.id)
        XCTAssertEqual(ids, ["en-US", "en-GB", "fr-FR", "es-ES", "de-DE", "de-CH", "sv-SE"])
        XCTAssertEqual(CueCallerUIModel.languageName("de-CH"), "German (Switzerland)")
        XCTAssertEqual(CueCallerUIModel.languageName("sv-SE"), "Swedish")
        XCTAssertTrue(CueCallLanguage.offered.contains("de-CH"))
        XCTAssertTrue(CueCallLanguage.offered.contains("sv-SE"))
    }

    /// Not an assertion: logs what Apple's Translation framework supports on this OS, for the report.
    func testReportAppleTranslationSupport() async {
        let avail = LanguageAvailability()
        let supported = await avail.supportedLanguages.map { $0.minimalIdentifier }.sorted()
        print("TRANSLATION supported:", supported.joined(separator: ", "))
        for target in ["fr-FR", "es-ES", "de", "de-CH", "sv-SE", "en-GB"] {
            let s = await avail.status(from: Locale.Language(identifier: "en-US"), to: Locale.Language(identifier: target))
            print("TRANSLATION en-US → \(target):", s == .installed ? "installed" : s == .supported ? "supported (download)" : "unsupported")
        }
    }
}

// MARK: - Helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
    func bump(_ s: String) { lock.lock(); _values.append(s); lock.unlock() }
}

/// URLProtocol stand-in for api.elevenlabs.io. Records every request; answers with `handler`
/// or fails with `failure`.
final class MockElevenLabsProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _failure: Error?

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var handler: ((URLRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var failure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); _failure = newValue; lock.unlock() }
    }
    static func reset() { lock.lock(); _requests = []; _handler = nil; _failure = nil; lock.unlock() }

    /// The body, whether URLSession kept it as data or turned it into a stream.
    static func body(of r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var r = request
        if r.httpBody == nil, r.httpBodyStream != nil { r.httpBody = Self.body(of: request) }
        Self.lock.lock(); Self._requests.append(r); let h = Self._handler, f = Self._failure; Self.lock.unlock()
        if let f { client?.urlProtocol(self, didFailWithError: f); return }
        let (status, data) = h?(r) ?? (500, Data())
        let resp = HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
