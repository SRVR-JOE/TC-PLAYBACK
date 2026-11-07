import XCTest
@testable import TCPlayback

/// Stacked calls (several calls on one mark, same-frame marks merged) and the camera presets.
final class ToolsCueCallerStackTests: XCTestCase {
    private func settings(_ areas: [CueCallArea], standby: Bool = true, lead: Double = 5) -> CueCallerSettings {
        var s = CueCallerSettings()
        s.enabled = true; s.sayStandby = standby; s.standbyLead = lead; s.areas = areas
        return s
    }
    private let templates: CueCallPhrase = { kind, note, lang in CueCallTemplates.text(kind, note: note, language: lang) }

    /// Standby and go text for one mark, phrased by the app's templates, no translation.
    private func phrased(_ note: String, language: String, names: [String] = []) async -> (standby: String, go: String) {
        let a = CueCallArea(name: "A", language: language)
        let p = await CueCallScheduler.prepare(marks: [CueCallMark(time: 10, note: note)], settings: settings([a]),
                                               noteLanguage: language, translator: PassthroughCueCallTranslator(),
                                               phrase: templates, cameraNames: names)
        return (p.first { $0.call.kind == .standby }?.call.text ?? "", p.first { $0.call.kind == .go }?.call.text ?? "")
    }

    private func occurrences(of word: String, in s: String) -> Int {
        let re = try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}])")
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    // MARK: Lines

    func testLineParsing() {
        XCTAssertEqual(CueCallStack.lines("Camera 3, push in"), ["Camera 3, push in"], "one line = the old format")
        XCTAssertEqual(CueCallStack.lines("  Camera 3, push in \n\n Camera 5, wide\r\n  \n"), ["Camera 3, push in", "Camera 5, wide"])
        XCTAssertEqual(CueCallStack.lines(""), [])
        XCTAssertEqual(CueCallStack.lines(" \n "), [])
        XCTAssertEqual(CueCallStack.editingLines(""), [""])
        XCTAssertEqual(CueCallStack.editingLines("a\n"), ["a", ""], "the editor keeps a line just added")
        XCTAssertEqual(CueCallStack.note(["a", "b"]), "a\nb")
        XCTAssertEqual(CueCallStack.tidy("a\n\n b \n"), "a\nb")
        XCTAssertEqual(CueCallStack.summary("a\nb"), "a · b")
        let p = CuePoint(trackID: UUID(), time: 1, name: "X")
        p.callNote = "Camera 3, push in\nCamera 5, wide"
        XCTAssertEqual(p.callLines, ["Camera 3, push in", "Camera 5, wide"])
        XCTAssertEqual(p.callCount, 2)
    }

    func testSingleLineIsUnchanged() async {
        let one = await phrased("Camera 3, push in slow", language: "en-US")
        XCTAssertEqual(one.standby, "Standby, Camera 3, push in slow")
        XCTAssertEqual(one.go, "Camera 3, push in slow… go")
        let r = CueCallScheduler.requests(marks: [CueCallMark(time: 1, note: " Lights ")], settings: settings([CueCallArea(name: "A", language: "en-US")], standby: false))
        XCTAssertEqual(r.map(\.text), ["Lights"])
        XCTAssertEqual(r.first?.lines.count, 1)
    }

    // MARK: Phrasing

    func testPhrasingOneTwoThreeLinesPerLanguage() async {
        struct Case { let lang: String; let lines: [String]; let standby: [String]; let go: [String]; let goWord: String }
        let cases = [
            Case(lang: "en-US", lines: ["Camera 3, push in", "Camera 5, wide", "Camera 7, tight"],
                 standby: ["Standby, Camera 3, push in", "Standby, Camera 3, push in. Camera 5, wide", "Standby, cameras 3, 5 and 7"],
                 go: ["Camera 3, push in… go", "Camera 3, push in. Camera 5, wide… go", "Camera 3, push in. Camera 5, wide. Camera 7, tight… go"],
                 goWord: "go"),
            Case(lang: "es-MX", lines: ["Cámara 3, acercar", "Cámara 5, abierto", "Cámara 7, cerrado"],
                 standby: ["Atención, Cámara 3, acercar", "Atención, Cámara 3, acercar. Cámara 5, abierto", "Atención, cámaras 3, 5 y 7"],
                 go: ["Cámara 3, acercar… ya", "Cámara 3, acercar. Cámara 5, abierto… ya", "Cámara 3, acercar. Cámara 5, abierto. Cámara 7, cerrado… ya"],
                 goWord: "ya"),
            Case(lang: "de-DE", lines: ["Kamera 3, ranfahren", "Kamera 5, weit", "Kamera 7, eng"],
                 standby: ["Achtung, Kamera 3, ranfahren", "Achtung, Kamera 3, ranfahren. Kamera 5, weit", "Achtung, Kameras 3, 5 und 7"],
                 go: ["Kamera 3, ranfahren… los", "Kamera 3, ranfahren. Kamera 5, weit… los", "Kamera 3, ranfahren. Kamera 5, weit. Kamera 7, eng… los"],
                 goWord: "los"),
            Case(lang: "sv-SE", lines: ["Kamera 3, åk in", "Kamera 5, bred", "Kamera 7, tight"],
                 standby: ["Stand by, Kamera 3, åk in", "Stand by, Kamera 3, åk in. Kamera 5, bred", "Stand by, kameror 3, 5 och 7"],
                 go: ["Kamera 3, åk in… kör", "Kamera 3, åk in. Kamera 5, bred… kör", "Kamera 3, åk in. Kamera 5, bred. Kamera 7, tight… kör"],
                 goWord: "kör"),
        ]
        for c in cases {
            for n in 1...3 {
                let r = await phrased(c.lines.prefix(n).joined(separator: "\n"), language: c.lang)
                XCTAssertEqual(r.standby, c.standby[n - 1], "\(c.lang) standby, \(n) lines")
                XCTAssertEqual(r.go, c.go[n - 1], "\(c.lang) go, \(n) lines")
                XCTAssertTrue(r.go.hasSuffix(c.goWord), "\(c.lang): go word last")
                XCTAssertEqual(occurrences(of: c.goWord, in: r.go), 1, "\(c.lang): one go only")
                XCTAssertEqual(occurrences(of: c.goWord, in: r.standby), 0, "\(c.lang): no go in the standby")
            }
        }
    }

    func testJapaneseAndChineseUseFullStop() async {
        let ja = await phrased("カメラ3、プッシュイン\nカメラ5、ワイド", language: "ja-JP")
        XCTAssertEqual(ja.go, "カメラ3、プッシュイン。カメラ5、ワイド… キュー")
        XCTAssertEqual(occurrences(of: "キュー", in: ja.go), 1)
        let three = await phrased("カメラ3、プッシュイン\nカメラ5、ワイド\nカメラ7、タイト", language: "ja-JP")
        XCTAssertEqual(three.standby, "スタンバイ、カメラ3、5、7")
        XCTAssertEqual(CueCallStack.join(["摄像机3，推", "摄像机5，广角。"], language: "zh-Hans"), "摄像机3，推。摄像机5，广角")
    }

    func testJoinTidiesPunctuationAndCase() {
        XCTAssertEqual(CueCallStack.join(["Camera 3, push in.", "camera 5, wide,"], language: "en-US"), "Camera 3, push in. Camera 5, wide")
        XCTAssertEqual(CueCallStack.list(["3"], language: "en"), "3")
        XCTAssertEqual(CueCallStack.list(["3", "5"], language: "fr-FR"), "3 et 5")
    }

    func testShortStandbyWithoutCamerasFallsBackToTheLines() async {
        let r = await phrased("Lights out\nHaze on\nStrobes", language: "en-US")
        XCTAssertEqual(r.standby, "Standby, Lights out. Haze on. Strobes", "no camera to name: the lines themselves")
        XCTAssertEqual(r.go, "Lights out. Haze on. Strobes… go")
    }

    func testBuiltInWordingAlsoStacks() async {
        let a = CueCallArea(name: "A", language: "en-US")
        let calls = await CueCallScheduler.build(marks: [CueCallMark(time: 10, note: "Camera 3, push in\nCamera 5, wide")],
                                                 settings: settings([a]), noteLanguage: "en-US", translator: PassthroughCueCallTranslator())
        XCTAssertEqual(calls.first { $0.kind == .go }?.text, "Camera 3, push in. Camera 5, wide… go.")
        XCTAssertEqual(calls.first { $0.kind == .go }?.lineCount, 2)
    }

    // MARK: Same frame

    func testSameFrameMarksMergeAcrossLanesInOneArea() {
        let lx = UUID(), video = UUID()
        let cams = CueCallArea(name: "Cams", language: "en-US")                       // every lane
        var lights = CueCallArea(name: "LX", language: "en-US"); lights.laneIDs = [lx]
        let a = CueCallMark(time: 52, name: "Chorus", note: "Camera 3, push in")
        let b = CueCallMark(time: 52 + 0.5 / 30, name: "Gerbs", note: "Camera 5, wide", typeID: lx)
        let c = CueCallMark(time: 52, name: "Content", note: "Camera 7, tight", typeID: video)
        let far = CueCallMark(time: 52 + 2.0 / 30, name: "Later", note: "Camera 1, hold")
        let s = settings([cams, lights], standby: false)
        let r = CueCallScheduler.requests(marks: [far, b, a, c], settings: s, frame: 1.0 / 30)
        let camGo = r.filter { $0.areaID == cams.id }
        XCTAssertEqual(camGo.count, 2, "three marks in one frame are one call; two frames later is its own")
        XCTAssertEqual(camGo[0].lines.map(\.text), ["Camera 3, push in", "Camera 7, tight", "Camera 5, wide"], "time order, then as given")
        XCTAssertEqual(Set(camGo[0].markIDs), [a.id, b.id, c.id])
        XCTAssertEqual(camGo[0].at, 52)
        XCTAssertEqual(camGo[1].lines.map(\.text), ["Camera 1, hold"])
        let lxGo = r.filter { $0.areaID == lights.id }
        XCTAssertEqual(lxGo.map(\.lines.count), [1], "the LX area only calls its own lane")

        var off = s; off.stackSameFrame = false
        XCTAssertEqual(CueCallScheduler.requests(marks: [a, b, c], settings: off).filter { $0.areaID == cams.id }.count, 3)
    }

    func testMergedStackIsOneCallNotACutOff() async {
        let cams = CueCallArea(name: "Cams", language: "en-US")
        let m1 = CueCallMark(time: 20, note: "Camera 3, push in"), m2 = CueCallMark(time: 20, note: "Camera 5, wide", typeID: UUID())
        let calls = await CueCallScheduler.build(marks: [m1, m2], settings: settings([cams]), noteLanguage: "en-US",
                                                 translator: PassthroughCueCallTranslator(), phrase: templates)
        XCTAssertEqual(calls.filter { $0.kind == .go }.map(\.text), ["Camera 3, push in. Camera 5, wide… go"])
        let t = CueCallScheduler.timeline(calls) { _ in (2, false) }
        XCTAssertTrue(t.allSatisfy { $0.cutAt == nil })
    }

    func testSettingOnByDefaultAndOldSettingsStillLoad() throws {
        XCTAssertTrue(CueCallerSettings().stackSameFrame)
        let old = #"{"enabled":true,"source":"playback","standbyLead":7,"sayStandby":true,"includeMarkName":false,"dedicatedCallChannels":true,"onlyMarksWithNotes":true,"areas":[{"id":"6E1B1E62-6C55-4F0B-9E43-4C3B7C0A0A01","name":"Cámaras","language":"es-MX","outputChannels":[2,3],"laneIDs":[],"enabled":true,"gainDB":0,"rate":0.5}]}"#
        let s = try JSONDecoder().decode(CueCallerSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.standbyLead, 7)
        XCTAssertEqual(s.areas.first?.name, "Cámaras", "areas survive a settings file from before stacks")
        XCTAssertTrue(s.stackSameFrame)
    }

    // MARK: Translation per line

    func testEachLineTranslatedSeparatelyAndDigitsSurvive() async {
        let counter = Counter()
        // A translator that turns digits full-width (the number guard puts them back) and counts calls.
        let engine: AppleCueCallTranslator.Engine = { text, _, _ in
            await counter.add(text)
            let full = text.unicodeScalars.map { $0.value >= 0x30 && $0.value <= 0x39 ? String(UnicodeScalar($0.value + 0xFEE0)!) : String($0) }.joined()
            return "ES:" + full.replacingOccurrences(of: "Camera", with: "Cámara")
        }
        let t = AppleCueCallTranslator(store: CueCallTranslationStore(directory: nil), engine: engine)
        let es = CueCallArea(name: "Cámaras", language: "es-MX")
        let marks = [CueCallMark(time: 10, note: "Camera 3, push in\nCamera 12, wide"),
                     CueCallMark(time: 30, note: "Camera 12, wide")]
        let p = await CueCallScheduler.prepare(marks: marks, settings: settings([es], standby: false), noteLanguage: "en-US",
                                               translator: t, phrase: templates)
        XCTAssertEqual(p.map(\.lines), [["ES:Cámara 3, push in", "ES:Cámara 12, wide"], ["ES:Cámara 12, wide"]])
        XCTAssertEqual(p[0].call.text, "ES:Cámara 3, push in. ES:Cámara 12, wide… ya")
        for c in p { XCTAssertEqual(CueCallNumberGuard.numbers(in: c.call.text).filter { !$0.isEmpty }, c.call.markID == marks[0].id ? ["3", "12"] : ["12"]) }
        let seen = await counter.texts
        XCTAssertEqual(seen.sorted(), ["Camera 12, wide", "Camera 3, push in"], "one translation per distinct line")
    }

    func testPerLineCorrection() async {
        let store = CueCallTranslationStore(directory: nil)
        let mark = CueCallMark(time: 10, note: "Camera 3, push in\nCamera 5, wide")
        store.setOverride(markID: mark.id, language: "es-MX", line: "Camera 5, wide", text: "Cámara 5, abre")
        XCTAssertEqual(store.override(markID: mark.id, language: "es-ES", line: " Camera 5,  wide ")?.text, "Cámara 5, abre", "matched per language key and line")
        XCTAssertNil(store.override(markID: mark.id, language: "es-MX", line: "Camera 3, push in"))
        // A correction written before stacks (whole note = this one line) still applies to that line.
        store.setOverride(markID: mark.id, language: "fr-FR", sourceText: "Camera 3, push in", text: "Caméra 3, avance")
        XCTAssertEqual(store.activeOverride(markID: mark.id, language: "fr-FR", line: "Camera 3, push in"), "Caméra 3, avance")

        let es = CueCallArea(name: "Cámaras", language: "es-MX")
        let p = await CueCallScheduler.prepare(marks: [mark], settings: settings([es], standby: false), noteLanguage: "en-US",
                                               translator: UpperTranslator(), phrase: templates,
                                               lineOverride: { store.activeOverride(markID: $0, language: $2, line: $1) })
        XCTAssertEqual(p.first?.lines, ["[es-MX] CAMERA 3, PUSH IN", "Cámara 5, abre"])
        store.setOverride(markID: mark.id, language: "es-MX", line: "Camera 5, wide", text: "")
        XCTAssertNil(store.override(markID: mark.id, language: "es-MX", line: "Camera 5, wide"))
    }

    // MARK: Long stacks

    func testLongStackStartsEarlyAndMovesItsStandby() {
        let area = UUID(), mark = UUID()
        let go = CueCall(markID: mark, areaID: area, kind: .go, at: 10, text: "long", lineCount: 3)
        let sb = CueCall(markID: mark, areaID: area, kind: .standby, at: 5, text: "Standby, cameras 3, 5 and 7", lineCount: 3)
        let t = CueCallScheduler.timeline([sb, go], timing: { c in c.kind == .go ? CueCallTiming(duration: 4.4, goOnset: 4.2) : CueCallTiming(duration: 3) })
        let g = t.first { $0.call.kind == .go }!, s = t.first { $0.call.kind == .standby }!
        XCTAssertEqual(g.start, 5.8, accuracy: 1e-9, "the go word still lands on the mark")
        XCTAssertTrue(g.startsEarly)
        XCTAssertEqual(CueCallScheduler.leadIn(g), 4.2, accuracy: 1e-9)
        XCTAssertEqual(s.start + s.duration, 5.8 - CueCallScheduler.standbyGap, accuracy: 1e-9, "standby moved earlier, not skipped")
        XCTAssertNil(s.cutAt, "nothing cut")
        XCTAssertNil(g.cutAt)

        // A stack that fits isn't touched; a plain call keeps the old rule.
        let short = CueCallScheduler.timeline([sb, go], timing: { _ in CueCallTiming(duration: 1.5) })
        XCTAssertFalse(short.contains { $0.startsEarly })
        XCTAssertEqual(short.first { $0.call.kind == .standby }!.start, 5)
        let single = CueCall(markID: mark, areaID: area, kind: .go, at: 10, text: "long")
        let one = CueCallScheduler.timeline([sb, single], timing: { _ in CueCallTiming(duration: 5) })
        XCTAssertFalse(one.contains { $0.startsEarly })
    }

    func testEstimatedEarlyStartForTheReview() {
        let a = CueCallArea(name: "Cams", language: "en-US")
        let long = CueCallMark(time: 60, note: (1...6).map { "Camera \($0), slow push in and hold on the lead vocal" }.joined(separator: "\n"))
        let fine = CueCallMark(time: 120, note: "Camera 3, push in\nCamera 5, wide")
        let early = CueCallScheduler.estimatedEarlyStarts(marks: [long, fine], settings: settings([a], lead: 8), noteLanguage: "en-US")
        XCTAssertNotNil(early[long.id])
        XCTAssertGreaterThan(early[long.id] ?? 0, 4)
        XCTAssertNil(early[fine.id])
    }

    // MARK: Camera presets

    func testCameraTapInsertAndSwap() {
        typealias E = CueCallPresetEditing
        XCTAssertEqual(E.tapCamera("Camera 3", line: "", names: []), .replace("Camera 3, "))
        XCTAssertEqual(E.tapCamera("Camera 5", line: "Camera 3, ", names: []), .replace("Camera 5, "), "camera only: swap")
        XCTAssertEqual(E.tapCamera("Camera 5", line: "Cam 3", names: []), .replace("Camera 5, "))
        XCTAssertEqual(E.tapCamera("Camera 5", line: "Camera 3, push in", names: []), .newLine("Camera 5, "), "full call: stack")
        XCTAssertEqual(E.tapCamera("Jib", line: "Lights out", names: ["Jib"]), .newLine("Jib, "))
        XCTAssertEqual(E.tapCamera("Camera 3", line: "Jib, ", names: ["Jib"]), .replace("Camera 3, "))
        XCTAssertEqual(E.swapCamera("Jib", line: "Camera 3, push in", names: ["Jib"]), "Jib, push in")
        XCTAssertEqual(E.swapCamera("Camera 2", line: "Steadicam, follow", names: ["Steadicam"]), "Camera 2, follow")
        XCTAssertEqual(E.swapCamera("Camera 2", line: "push in", names: []), "Camera 2, push in")

        XCTAssertEqual(E.tapShot("Push in", line: "Camera 3, "), "Camera 3, push in", "two taps make a call")
        XCTAssertEqual(E.tapShot("Hold", line: "Camera 3, push in"), "Camera 3, push in, hold")
        XCTAssertEqual(E.tapShot("Wide", line: ""), "Wide")
        XCTAssertEqual(E.tapShot("PTZ left", line: "Camera 3,"), "Camera 3, PTZ left")

        let lead = E.leadingCamera(in: "Camera 12, wide", names: [])
        XCTAssertEqual(lead?.ref, .numbered("12")); XCTAssertEqual(lead?.rest, "wide")
        XCTAssertNil(E.leadingCamera(in: "Cameraman, wide", names: []))
        XCTAssertNil(E.leadingCamera(in: "Jibber", names: ["Jib"]), "whole names only")
        XCTAssertEqual(E.leadingCamera(in: "jib - sweep", names: ["Jib"])?.ref, .named("Jib"))
    }

    func testNoteLevelEditsForTheEditor() {
        typealias E = CueCallPresetEditing
        var r = E.applyCamera("Camera 3", to: "", line: 0, names: [])
        XCTAssertEqual(r.note, "Camera 3, "); XCTAssertEqual(r.line, 0)
        let n = E.applyShot("Push in", to: r.note, line: r.line)
        XCTAssertEqual(n, "Camera 3, push in")
        r = E.applyCamera("Camera 5", to: n, line: 0, names: [])
        XCTAssertEqual(r.note, "Camera 3, push in\nCamera 5, "); XCTAssertEqual(r.line, 1, "a full line stacks a new one")
        XCTAssertEqual(E.applyShot("Wide", to: r.note, line: 1), "Camera 3, push in\nCamera 5, wide")
        XCTAssertEqual(E.applyCamera("Camera 7", to: "Camera 3, push in\n", line: 0, names: []).note, "Camera 3, push in\nCamera 7, ", "reuses the empty line")
        let add = E.addLine(to: "Camera 3, push in", after: 0)
        XCTAssertEqual(add.note, "Camera 3, push in\n"); XCTAssertEqual(add.line, 1)
        XCTAssertEqual(E.addLine(to: "Camera 3, push in\n", after: 0).note, "Camera 3, push in\n", "never two blanks")
        XCTAssertEqual(E.moveLine(in: "a\nb\nc", from: 2, to: 0), "c\na\nb")
        XCTAssertEqual(E.removeLine(from: "a\nb", at: 0), "b")
        XCTAssertEqual(E.applySwap("Jib", to: "a\nCamera 3, push in", line: 1, names: ["Jib"]), "a\nJib, push in")
    }

    func testActiveCameraKey() {
        var p = CueCameraPresets()
        XCTAssertEqual(CueCallPresetEditing.activeCamera(line: "Camera 3, push in", presets: p), 2)
        XCTAssertNil(CueCallPresetEditing.activeCamera(line: "push in", presets: p))
        p.cameras[6] = "Jib"
        XCTAssertEqual(CueCallPresetEditing.activeCamera(line: "Jib, sweep", presets: p), 6)
        XCTAssertNil(CueCallPresetEditing.activeCamera(line: "Camera 7, sweep", presets: p), "Cam 7 is called Jib now")
    }

    func testPresetsPersistWithDefaults() throws {
        let d = UserDefaults(suiteName: "stack-tests-\(UUID().uuidString)")!
        var p = CueCameraPresets.load(d)
        XCTAssertEqual(p.cameras.first, "Camera 1"); XCTAssertEqual(p.cameras.count, 12)
        XCTAssertEqual(p.shots, CueCameraPresets.defaultShots)
        XCTAssertEqual(p.keyLabel(0), "Cam 1")
        p.cameras[6] = "Jib"; p.cameras[8] = "Steadicam"; p.cameras[11] = "Drone"
        p.save(d)
        let back = CueCameraPresets.load(d)
        XCTAssertEqual(back.name(6), "Jib"); XCTAssertEqual(back.keyLabel(8), "Steadicam")
        XCTAssertEqual(back.customNames, ["Jib", "Steadicam", "Drone"])
        // Blank or short saved lists fall back to the numbers.
        let partial = try JSONDecoder().decode(CueCameraPresets.self, from: Data(#"{"cameras":["", "Jib"]}"#.utf8))
        XCTAssertEqual(partial.cameras[0], "Camera 1"); XCTAssertEqual(partial.cameras[1], "Jib"); XCTAssertEqual(partial.cameras[11], "Camera 12")
        XCTAssertEqual(partial.shots, CueCameraPresets.defaultShots)
    }

    func testRenamedCamerasInSpokenText() async {
        var presets = CueCameraPresets()
        presets.cameras[6] = "Jib"; presets.cameras[8] = "Steadicam"; presets.cameras[11] = "Drone"
        let names = presets.customNames
        // Key 7, then Push in; key 9 stacks; key 12 stacks.
        var r = CueCallPresetEditing.applyCamera(presets.name(6), to: "", line: 0, names: names)
        var note = CueCallPresetEditing.applyShot("Push in", to: r.note, line: r.line)
        r = CueCallPresetEditing.applyCamera(presets.name(8), to: note, line: r.line, names: names)
        note = CueCallPresetEditing.applyShot("Follow", to: r.note, line: r.line)
        r = CueCallPresetEditing.applyCamera(presets.name(2), to: note, line: r.line, names: names)
        note = CueCallPresetEditing.applyShot("Wide", to: r.note, line: r.line)
        XCTAssertEqual(note, "Jib, push in\nSteadicam, follow\nCamera 3, wide")

        let en = await phrased(note, language: "en-US", names: names)
        XCTAssertEqual(en.go, "Jib, push in. Steadicam, follow. Camera 3, wide… go")
        XCTAssertEqual(en.standby, "Standby, camera 3, Jib and Steadicam")
        // The voice gets the respelling for its language.
        XCTAssertEqual(CueCallLexicon.speakable("Jib, push in", language: "de-DE"), "Dschibb, push in")
        XCTAssertEqual(CueCallLexicon.speakable(en.go, language: "en-US"), "Jib, push in. Steady-cam, follow. Camera 3, wide… go")
        // Names go through translation like any word; camera numbers stay digits.
        let es = CueCallArea(name: "Cámaras", language: "es-MX")
        let p = await CueCallScheduler.prepare(marks: [CueCallMark(time: 10, note: note)], settings: settings([es]), noteLanguage: "en-US",
                                               translator: UpperTranslator(), phrase: templates, cameraNames: names)
        XCTAssertEqual(p.first { $0.call.kind == .standby }?.call.text, "Atención, cámara 3, [es-MX] JIB y [es-MX] STEADICAM")
    }
}

private struct UpperTranslator: CueCallTranslator {
    func translate(_ text: String, from: String, to: String) async throws -> String { "[\(to)] " + text.uppercased() }
}

private actor Counter {
    var texts: [String] = []
    func add(_ t: String) { texts.append(t) }
}
