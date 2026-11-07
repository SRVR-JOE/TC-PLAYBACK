import AVFoundation
import XCTest
@testable import TCPlayback

/// Language side of the cue caller: templates, translation cache/overrides, number safety,
/// crew vocabulary, voice ranking, levelling and offline speech rendering. Nothing here plays
/// audio; speech is rendered into buffers only.
final class ToolsCueCallerLanguageTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuecall-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Stand-in machine translator that counts calls.
    private final class FakeEngine: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        let transform: @Sendable (String, String, String) -> String
        init(_ t: @escaping @Sendable (String, String, String) -> String) { transform = t }
        var engine: AppleCueCallTranslator.Engine {
            { text, s, t in
                self.lock.lock(); self._calls += 1; self.lock.unlock()
                return self.transform(text, s, t)
            }
        }
    }

    private func translator(_ fake: FakeEngine) -> AppleCueCallTranslator {
        AppleCueCallTranslator(store: CueCallTranslationStore(directory: dir.appendingPathComponent(UUID().uuidString)), engine: fake.engine)
    }

    /// Crude "Spanish": Camera → Cámara, push in → acercar, keeps everything else.
    private static let toSpanish: @Sendable (String, String, String) -> String = { text, _, _ in
        text.replacingOccurrences(of: "Camera", with: "Cámara").replacingOccurrences(of: "push in", with: "acercar")
    }

    // MARK: Templates

    func testGoWordIsLastForEveryLanguage() {
        let required = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh-Hans", "nl"]
        for k in required {
            XCTAssertTrue(CueCallTemplates.builtIn.contains { $0.language == k }, "missing template for \(k)")
        }
        let strip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for t in CueCallTemplates.builtIn {
            XCTAssertTrue(t.goWordIsLast, "\(t.language): go word not last")
            XCTAssertTrue(t.standby.contains(CueCallTemplate.placeholder))
            let call = t.goText("Camera 3, push in")
            XCTAssertTrue(call.trimmingCharacters(in: strip).hasSuffix(t.goWord), "\(t.language): \(call)")
            XCTAssertTrue(call.contains("Camera 3, push in"))
            XCTAssertEqual(t.goText(""), t.bareGo)
            XCTAssertTrue(t.bareGo.trimmingCharacters(in: strip).lowercased().hasSuffix(t.goWord.lowercased()))
            let parts = t.goParts("Camera 3")
            XCTAssertEqual(parts.goWord.lowercased(), t.goWord.lowercased())
            XCTAssertFalse(parts.lead.isEmpty)
        }
    }

    func testTemplateLookupAndPhrasing() {
        XCTAssertEqual(CueCallTemplates.text(.standby, note: "Camera 3", language: "en-US"), "Standby, Camera 3")
        XCTAssertEqual(CueCallTemplates.text(.go, note: "Camera 3", language: "en-GB"), "Camera 3… go")
        XCTAssertEqual(CueCallTemplates.text(.go, note: "Cámara 3", language: "es-MX"), "Cámara 3… ya")
        XCTAssertEqual(CueCallTemplates.text(.standby, note: "Caméra 2", language: "fr-FR"), "Attention, Caméra 2")
        XCTAssertEqual(CueCallTemplates.template(for: "de-AT").goWord, "los")
        XCTAssertEqual(CueCallTemplates.template(for: "pt-PT").language, "pt")
        XCTAssertEqual(CueCallTemplates.template(for: "zh-TW").language, "zh-Hant")
        XCTAssertEqual(CueCallTemplates.template(for: "zh-CN").language, "zh-Hans")
        XCTAssertEqual(CueCallTemplates.template(for: "sv-SE").language, "en")
        // Trailing punctuation in the note isn't doubled.
        XCTAssertEqual(CueCallTemplates.text(.go, note: "Camera 3, push in.", language: "en-US"), "Camera 3, push in… go")
    }

    func testCustomTemplateWinsOnlyWhenValid() throws {
        let good = CueCallTemplate(language: "es", standby: "Prevenido, {note}", go: "{note}… dale", goWord: "dale", bareGo: "Dale")
        let bad = CueCallTemplate(language: "fr", standby: "{note}", go: "Top, {note}", goWord: "top", bareGo: "Top")
        XCTAssertEqual(CueCallTemplates.template(for: "es-AR", custom: [good]).goWord, "dale")
        XCTAssertFalse(bad.goWordIsLast)
        XCTAssertEqual(CueCallTemplates.template(for: "fr-FR", custom: [bad]).goWord, "top")
        XCTAssertEqual(CueCallTemplates.template(for: "fr-FR", custom: [bad]).go, "{note}… top")
        // Codable round trip, for per-area edits.
        let data = try JSONEncoder().encode([good])
        XCTAssertEqual(try JSONDecoder().decode([CueCallTemplate].self, from: data), [good])
    }

    // MARK: Translation

    func testSameLanguagePassthrough() async throws {
        let fake = FakeEngine(Self.toSpanish)
        let t = translator(fake)
        let out = try await t.translate("Cam 3, push in", from: "en-US", to: "en-GB")
        XCTAssertEqual(out, "Cam 3, push in")
        let r = await t.call(note: "Cam 3, push in", markID: UUID(), from: "es-ES", to: "es-MX")
        XCTAssertEqual(r.text, "Cam 3, push in")
        XCTAssertEqual(r.origin, .passthrough)
        XCTAssertEqual(fake.calls, 0)
        XCTAssertTrue(CueCallLanguage.same("zh-Hans", "zh-CN"))
        XCTAssertFalse(CueCallLanguage.same("zh-Hans", "zh-TW"))
    }

    func testTranslationIsCachedAndPersisted() async throws {
        let fake = FakeEngine(Self.toSpanish)
        let t = AppleCueCallTranslator(store: CueCallTranslationStore(directory: dir), engine: fake.engine)
        let a = try await t.translate("Camera 3, push in", from: "en-US", to: "es-MX")
        XCTAssertEqual(a, "Cámara 3, acercar")
        let b = try await t.translate("Camera 3,  push in ", from: "en-GB", to: "es-ES")
        XCTAssertEqual(b, a)
        XCTAssertEqual(fake.calls, 1, "second request should come from the cache")
        // A fresh store on the same directory reads the JSON back.
        let fake2 = FakeEngine { _, _, _ in "WRONG" }
        let t2 = AppleCueCallTranslator(store: CueCallTranslationStore(directory: dir), engine: fake2.engine)
        let c = try await t2.translate("Camera 3, push in", from: "en-US", to: "es-MX")
        XCTAssertEqual(c, a)
        XCTAssertEqual(fake2.calls, 0)
        let r = await t2.call(note: "Camera 3, push in", markID: UUID(), from: "en-US", to: "es-MX")
        XCTAssertEqual(r.origin, .cache)
    }

    func testOverrideBeatsCacheAndGoesStaleWhenNoteChanges() async throws {
        let fake = FakeEngine(Self.toSpanish)
        let t = AppleCueCallTranslator(store: CueCallTranslationStore(directory: dir), engine: fake.engine)
        let mark = UUID()
        let note = "Camera 3, push in"
        _ = try await t.translate(note, from: "en-US", to: "es-MX")   // cached
        t.setOverride(markID: mark, language: "es-MX", note: note, text: "Cámara 3, cierra lento")

        let r = await t.call(note: note, markID: mark, from: "en-US", to: "es-ES")
        XCTAssertEqual(r.text, "Cámara 3, cierra lento")
        XCTAssertEqual(r.origin, .override)
        // The plain protocol path honours it too, by note text.
        let p = try await t.translate(note, from: "en-US", to: "es-MX")
        XCTAssertEqual(p, "Cámara 3, cierra lento")
        // Overrides win even for the operator's own language.
        t.setOverride(markID: mark, language: "en-US", note: note, text: "Three, push in slow")
        let en = await t.call(note: note, markID: mark, from: "en-US", to: "en-GB")
        XCTAssertEqual(en.text, "Three, push in slow")

        // Persisted.
        let store2 = CueCallTranslationStore(directory: dir)
        XCTAssertEqual(store2.activeOverride(markID: mark, language: "es", note: note), "Cámara 3, cierra lento")

        // Note edited: the old correction is kept for the UI but no longer spoken.
        let edited = "Camera 4, push in"
        let o = try XCTUnwrap(t.store.override(markID: mark, language: "es-MX"))
        XCTAssertTrue(o.isStale(currentNote: edited))
        let r2 = await t.call(note: edited, markID: mark, from: "en-US", to: "es-MX")
        XCTAssertEqual(r2.text, "Cámara 4, acercar")
        XCTAssertEqual(r2.origin, .translated)

        // Clearing.
        t.setOverride(markID: mark, language: "es", note: note, text: "  ")
        XCTAssertNil(t.store.override(markID: mark, language: "es-MX"))
    }

    func testDigitsSurviveTranslation() async throws {
        // Translator that keeps digits: intact.
        let keep = translator(FakeEngine(Self.toSpanish))
        let r1 = await keep.call(note: "Camera 3 to Camera 12, cue 2.5", markID: UUID(), from: "en", to: "es")
        XCTAssertEqual(CueCallNumberGuard.numbers(in: r1.text), ["3", "12", "2.5"])
        XCTAssertEqual(r1.numbers, .intact)

        // Full-width digits (CJK output) are folded back to ASCII.
        let wide = translator(FakeEngine { _, _, _ in "カメラ３、プッシュイン" })
        let r2 = await wide.call(note: "Camera 3, push in", markID: UUID(), from: "en", to: "ja")
        XCTAssertEqual(r2.text, "カメラ3、プッシュイン")
        XCTAssertEqual(r2.numbers, .repaired)

        // Wrong number, same count: put back.
        let wrong = translator(FakeEngine { _, _, _ in "Cámara 8, acercar" })
        let r3 = await wrong.call(note: "Camera 3, push in", markID: UUID(), from: "en", to: "es")
        XCTAssertEqual(r3.text, "Cámara 3, acercar")
        XCTAssertEqual(r3.numbers, .repaired)

        // Number spelled out: unsafe, so the original note is called and nothing is cached.
        let fake = FakeEngine { _, _, _ in "Cámara tres, acercar" }
        let words = translator(fake)
        let r4 = await words.call(note: "Camera 3, push in", markID: UUID(), from: "en", to: "es")
        XCTAssertEqual(r4.text, "Camera 3, push in")
        XCTAssertEqual(r4.origin, .original)
        XCTAssertNotNil(r4.problem)
        do {
            _ = try await words.translate("Camera 3, push in", from: "en", to: "es")
            XCTFail("expected numbersChanged")
        } catch let e as CueCallTranslationError {
            XCTAssertEqual(e, .numbersChanged)
        }
        XCTAssertEqual(words.store.cacheCount, 0)

        // Localised decimal separator counts as the same number.
        XCTAssertEqual(CueCallNumberGuard.check(source: "cue 2.5", translated: "cue 2,5").outcome, .intact)
    }

    func testCamIsExpandedBeforeTranslation() async throws {
        let seen = FakeEngine { text, _, _ in text }
        let t = translator(seen)
        let out = try await t.translate("Cam 3 and Cams 1, 2", from: "en-US", to: "de-DE")
        XCTAssertEqual(out, "Camera 3 and Cameras 1, 2")
        XCTAssertEqual(CueCallLexicon.expandCam("cam3 wide", language: "de"), "Kamera 3 wide")
    }

    func testProtectedRangesCoverNumbersAndCrewTerms() {
        let s = "Jib 2 and PTZ 4 on LX cue"
        let words = CueCallNumberGuard.protectedRanges(in: s).map { String(s[$0]) }
        XCTAssertEqual(words, ["Jib", "2", "PTZ", "4", "LX"])
    }

    // MARK: Pronunciation

    func testSpeakableCrewTerms() {
        XCTAssertEqual(CueCallLexicon.speakable("Cam 3 Steadicam, SFX and LX, VT 2, PTZ 4", language: "en-US"),
                       "Camera 3 Steady-cam, S F X and L X, V T 2, P T Z 4")
        XCTAssertEqual(CueCallLexicon.speakable("Jib 1", language: "de-DE"), "Dschibb 1")
        XCTAssertEqual(CueCallLexicon.speakable("Cam 2", language: "es-MX"), "Cámara 2")
        // Whole words only.
        XCTAssertEqual(CueCallLexicon.speakable("ALEX", language: "en-US"), "ALEX")
        XCTAssertEqual(CueCallLexicon.speakable("camera", language: "en-US"), "camera")
    }

    // MARK: Voices

    func testVoiceRankingPrefersRegionThenQuality() {
        let all = [
            CueCallVoice(id: "a", name: "Monica", language: "es-ES", quality: .premium),
            CueCallVoice(id: "b", name: "Paulina", language: "es-MX", quality: .standard),
            CueCallVoice(id: "c", name: "Juan", language: "es-MX", quality: .enhanced),
            CueCallVoice(id: "d", name: "Samantha", language: "en-US", quality: .premium),
            CueCallVoice(id: "e", name: "Eddy", language: "es-MX", quality: .enhanced),
        ]
        let ranked = SpeechCueCallRenderer.rank(all, for: "es-MX").map(\.id)
        XCTAssertEqual(ranked, ["e", "c", "b", "a"])
        XCTAssertEqual(SpeechCueCallRenderer.rank(all, for: "es").first?.id, "a")
        XCTAssertEqual(all[0].qualityLabel, "Premium")
        // The live list never mixes languages.
        for v in SpeechCueCallRenderer.voices(for: "fr-FR") { XCTAssertEqual(CueCallLanguage.code(v.language), "fr") }
    }

    // MARK: Level

    func testLoudnessMeterMatchesReference() {
        // BS.1770: a full-scale 997 Hz sine reads −3.01 LUFS.
        let sr = 48_000.0
        let x = (0..<Int(sr * 3)).map { Float(sin(2 * Double.pi * 997 * Double($0) / sr)) }
        XCTAssertEqual(CueCallLoudness.integrated(x, sampleRate: sr), -3.01, accuracy: 0.1)
    }

    func testLevellingHitsTargetAndCeiling() {
        let sr = 48_000.0
        // Speech-like: 300 Hz bursts with a few sharp peaks.
        var x = (0..<Int(sr * 2)).map { i -> Float in
            let t = Double(i) / sr
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 3 * t))
            return 0.05 * env * Float(sin(2 * Double.pi * 300 * t))
        }
        for p in stride(from: 5000, to: x.count, by: 19_000) { x[p] = 0.4 }
        CueCallLoudness.level(&x, sampleRate: sr, targetLUFS: -16, ceilingDBFS: -1.5)
        let peak = x.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(20 * log10(peak), -1.5 + 0.01)
        XCTAssertEqual(CueCallLoudness.integrated(x, sampleRate: sr), -16, accuracy: 1.0)
    }

    func testTrimSilence() {
        let sr = 48_000.0
        let tone = (0..<4800).map { Float(0.5 * sin(Double($0) * 0.1)) }
        let padded = [Float](repeating: 0, count: 24_000) + tone + [Float](repeating: 0.00001, count: 24_000)
        let t = SpeechCueCallRenderer.trimSilence(padded, sampleRate: sr)
        XCTAssertLessThan(t.count, tone.count + Int(0.03 * sr) + 2)
        XCTAssertGreaterThanOrEqual(t.count, tone.count - 2)
    }

    // MARK: Rendering (buffers only — never played)

    func testRendererProducesTrimmedLevelledPCMAt48k() async throws {
        guard SpeechCueCallRenderer.bestVoice(for: "en-US") != nil || AVSpeechSynthesisVoice(language: "en-US") != nil else {
            throw XCTSkip("No English voice installed on this simulator")
        }
        let r = SpeechCueCallRenderer()
        let pcm: [Float]
        do {
            pcm = try await r.render("Standby, camera 3", language: "en-US", voiceID: nil, rate: 0.52, sampleRate: 48_000)
        } catch let e as SpeechCueCallRenderer.RenderError {
            throw XCTSkip("Speech synthesis unavailable on this simulator: \(e.localizedDescription)")
        }
        XCTAssertFalse(pcm.isEmpty)
        let dur = Double(pcm.count) / 48_000
        XCTAssertGreaterThan(dur, 0.4)
        XCTAssertLessThan(dur, 4)
        // Trimmed: sound within the first and last 40 ms.
        let peak = pcm.reduce(0) { max($0, abs($1)) }
        let thr = peak * 0.01
        let first = try XCTUnwrap(pcm.firstIndex { abs($0) > thr })
        let last = try XCTUnwrap(pcm.lastIndex { abs($0) > thr })
        XCTAssertLessThan(first, Int(0.04 * 48_000))
        XCTAssertGreaterThan(last, pcm.count - Int(0.04 * 48_000))
        XCTAssertLessThanOrEqual(20 * log10(peak), -1.5 + 0.01)
        XCTAssertEqual(CueCallLoudness.integrated(pcm, sampleRate: 48_000), -16, accuracy: 2)

        // Go call with a separately placed go word.
        let call = try await r.renderGo(note: "Camera 3", template: CueCallTemplates.template(for: "en-US"),
                                        language: "en-US", voiceID: nil, rate: 0.52, sampleRate: 48_000)
        let onset = try XCTUnwrap(call.goOnset)
        XCTAssertGreaterThan(onset, 0.2)
        XCTAssertLessThan(onset, call.duration - 0.05)
    }
}
