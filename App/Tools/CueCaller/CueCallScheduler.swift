import Foundation

/// Value copy of a cue point for the caller (no SwiftData).
struct CueCallMark: Hashable, Sendable {
    var id: UUID
    var time: TimeInterval
    var name: String
    var note: String
    /// Lane (cue type); the default "Cue" type when the point has none.
    var typeID: UUID

    init(id: UUID = UUID(), time: TimeInterval, name: String = "", note: String = "", typeID: UUID = CuePointType.defaultID) {
        self.id = id; self.time = time; self.name = name; self.note = note; self.typeID = typeID
    }
}

extension CueCallMark {
    init(_ p: CuePoint) {
        self.init(id: p.id, time: p.time, name: p.name, note: p.callNote, typeID: p.typeID ?? CuePointType.defaultID)
    }
}

/// A call with its audio length known, placed on the track timeline.
struct TimedCueCall: Hashable, Sendable {
    let call: CueCall
    /// Track time the voice starts. For `.go` this is mark − duration, so the last word lands on the mark.
    let start: TimeInterval
    let duration: TimeInterval
    /// Seconds from the voice's first sample to the start of the go word, when the renderer knows
    /// it (`.go` only). The go word lands on the mark; nil = the whole call ends on the mark.
    var goOnset: TimeInterval? = nil
    /// A later call in the same area starts before this one ends: fade out from here.
    var cutAt: TimeInterval? = nil
    /// The duration was estimated (audio not rendered yet).
    var estimated = false
    /// A stacked go too long for the gap after its standby: it starts earlier than usual and its
    /// standby was moved earlier to make room (shown in the Calls review).
    var startsEarly = false
    var end: TimeInterval { cutAt ?? start + duration }

    /// Identity across replans: one call per mark, area and kind.
    var key: CueCallKey { CueCallKey(markID: call.markID, areaID: call.areaID, kind: call.kind) }
}

struct CueCallKey: Hashable, Sendable {
    let markID: UUID
    let areaID: UUID
    let kind: CueCall.Kind
}

/// The words a caller says around the note, per language. Anything not listed is translated
/// from English by the area's translator.
enum CueCallWords {
    static func go(_ language: String) -> String? { table[primary(language)]?.go }
    static func standby(_ language: String) -> String? { table[primary(language)]?.standby }

    static func primary(_ language: String) -> String {
        String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
    static func sameLanguage(_ a: String, _ b: String) -> Bool { primary(a) == primary(b) }

    private static let table: [String: (standby: String, go: String)] = [
        "en": ("Standby", "go"),
        "es": ("Atención", "ya"),
        "fr": ("Attention", "top"),
        "de": ("Achtung", "los"),
        "it": ("Attenzione", "via"),
        "pt": ("Atenção", "já"),
        "nl": ("Stand-by", "go"),
        "sv": ("Stand by", "kör"),
        "ja": ("スタンバイ", "ゴー"),
        "ko": ("스탠바이", "고"),
        "zh": ("准备", "走"),
    ]
}

/// Injected phrase step: (kind, translated note, area language) → the full spoken line. Lets the
/// language part's templates (`CueCallTemplates.text(kind, note:, language:)`) replace the
/// built-in wording without the scheduler depending on them. The note is already in `language`.
typealias CueCallPhrase = @Sendable (CueCall.Kind, _ note: String, _ language: String) -> String

/// A crew correction for one line of one mark in one language (nil = none): (mark, line as
/// written, area language) → what to say instead.
typealias CueCallLineOverride = @Sendable (_ markID: UUID, _ line: String, _ language: String) -> String?

/// A built call plus the translated note it was made from (renderers that place the go word
/// themselves, e.g. `SpeechCueCallRenderer.renderGo(note:template:…)`, need the note, not the line).
struct PreparedCueCall: Hashable, Sendable {
    let call: CueCall
    /// The operator's note in the area's language; empty for a bare "go" / "standby". For a
    /// stack, the lines joined (go) or the short standby.
    let note: String
    /// Each stacked line in the area's language.
    var lines: [String] = []
}

/// What the scheduler needs to know about a call's audio.
struct CueCallTiming: Hashable, Sendable {
    var duration: TimeInterval
    /// Seconds from the voice start to the go word; nil = treat the end of the audio as the go.
    var goOnset: TimeInterval? = nil
    var estimated = false
}

/// Builds the calls for a track: which marks each area speaks, the text in the area's language,
/// and (once audio lengths are known) where each call sits on the timeline.
enum CueCallScheduler {
    /// One call before translation.
    struct Request: Hashable, Sendable {
        let markID: UUID
        let areaID: UUID
        let kind: CueCall.Kind
        let at: TimeInterval
        /// The operator's words (note, or mark name), untranslated; empty = the bare "go" / "standby".
        /// A stack is its lines joined with newlines.
        let text: String
        let language: String
        /// The stacked calls, in order (one for a plain call, none for a bare go).
        var lines: [CueCallLine] = []
        /// Every mark this call speaks for (more than one when marks on the same frame merged).
        var markIDs: [UUID] = []
    }

    /// Pure: what each enabled area should say, sorted by time. Applies lane filters,
    /// `onlyMarksWithNotes`, `includeMarkName` and the standby. With `stackSameFrame`, marks in an
    /// area within `frame` seconds of each other become one stacked call (on the earliest mark).
    static func requests(marks: [CueCallMark], settings: CueCallerSettings, frame: TimeInterval = 1.0 / 30) -> [Request] {
        var out: [Request] = []
        let sorted = marks.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        let window = max(0, frame) + 1e-6
        for area in settings.areas where area.enabled {
            var groups: [(time: TimeInterval, ids: [UUID], lines: [CueCallLine])] = []
            for m in sorted {
                if !area.laneIDs.isEmpty && !area.laneIDs.contains(m.typeID) { continue }
                var lines = CueCallStack.lines(m.note).map { CueCallLine(markID: m.id, text: $0) }
                if lines.isEmpty {
                    if settings.onlyMarksWithNotes { continue }
                    let name = settings.includeMarkName ? m.name.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if !name.isEmpty { lines = [CueCallLine(markID: m.id, text: name)] }
                }
                if settings.stackSameFrame, let last = groups.last, m.time - last.time <= window {
                    groups[groups.count - 1].ids.append(m.id)
                    groups[groups.count - 1].lines += lines
                } else {
                    groups.append((m.time, [m.id], lines))
                }
            }
            for g in groups {
                let text = g.lines.map(\.text).joined(separator: "\n")
                if settings.sayStandby && settings.standbyLead > 0 {
                    out.append(Request(markID: g.ids[0], areaID: area.id, kind: .standby, at: g.time - settings.standbyLead,
                                       text: text, language: area.language, lines: g.lines, markIDs: g.ids))
                }
                out.append(Request(markID: g.ids[0], areaID: area.id, kind: .go, at: g.time, text: text,
                                   language: area.language, lines: g.lines, markIDs: g.ids))
            }
        }
        return out.sorted { ($0.at, $0.kind == .go ? 1 : 0) < ($1.at, $1.kind == .go ? 1 : 0) }
    }

    /// The spoken line: "Standby, camera 3 push in slow." / "Camera 3 push in slow… go."
    static func compose(_ kind: CueCall.Kind, text: String, word: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".,;")))
        switch kind {
        case .standby: return t.isEmpty ? "\(word)." : "\(word), \(t)."
        case .go: return t.isEmpty ? capitalizedFirst(word) + "." : "\(t)… \(word)."
        }
    }

    private static func capitalizedFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Translates and composes every request. Translation failures fall back to the operator's
    /// words (a call in the wrong language beats a missing call). Results are cached per run.
    static func build(marks: [CueCallMark], settings: CueCallerSettings, noteLanguage: String,
                      translator: any CueCallTranslator, phrase: CueCallPhrase? = nil,
                      lineOverride: CueCallLineOverride? = nil, cameraNames: [String] = [],
                      frame: TimeInterval = 1.0 / 30) async -> [CueCall] {
        await prepare(marks: marks, settings: settings, noteLanguage: noteLanguage, translator: translator,
                      phrase: phrase, lineOverride: lineOverride, cameraNames: cameraNames, frame: frame).map(\.call)
    }

    /// `build`, keeping each call's translated note. The translator returns only the translated
    /// note; `phrase` (when given) turns it into the spoken line, otherwise the built-in words do.
    ///
    /// Stacks: each line is translated on its own (cached per line; `lineOverride` is a crew
    /// correction for one line), then phrased once: the go is the lines joined with one go word
    /// last; the standby is the lines joined, or for 3+ lines just the leading cameras
    /// ("Standby, cameras 3, 5 and 7"). `cameraNames` are renamed cameras to recognise.
    static func prepare(marks: [CueCallMark], settings: CueCallerSettings, noteLanguage: String,
                        translator: any CueCallTranslator, phrase: CueCallPhrase? = nil,
                        lineOverride: CueCallLineOverride? = nil, cameraNames: [String] = [],
                        frame: TimeInterval = 1.0 / 30) async -> [PreparedCueCall] {
        var cache: [String: String] = [:]
        func tr(_ text: String, to lang: String) async -> String {
            if text.isEmpty || CueCallWords.sameLanguage(noteLanguage, lang) { return text }
            let k = lang + "\u{1}" + text
            if let hit = cache[k] { return hit }
            let r = (try? await translator.translate(text, from: noteLanguage, to: lang)) ?? text
            cache[k] = r
            return r
        }
        var out: [PreparedCueCall] = []
        for r in requests(marks: marks, settings: settings, frame: frame) {
            var lines: [String] = []
            for l in r.lines {
                if let o = lineOverride?(l.markID, l.text, r.language)?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
                    lines.append(o)
                } else {
                    lines.append(await tr(l.text, to: r.language))
                }
            }
            var note = lines.count > 1 ? CueCallStack.join(lines, language: r.language) : (lines.first ?? "")
            if r.kind == .standby, lines.count >= 3 {
                var refs: [CueCameraRef] = []
                for l in r.lines {
                    guard let lead = CueCallPresetEditing.leadingCamera(in: l.text, names: cameraNames) else { continue }
                    switch lead.ref {
                    case .numbered: refs.append(lead.ref)
                    case .named(let n): refs.append(.named(await tr(n, to: r.language)))
                    }
                }
                if let short = CueCallStack.standbySummary(refs, language: r.language) { note = short }
            }
            let line: String
            if let phrase {
                line = phrase(r.kind, note, r.language)
            } else {
                let known = r.kind == .go ? CueCallWords.go(r.language) : CueCallWords.standby(r.language)
                var word = known ?? ""
                if known == nil { word = await tr(r.kind == .go ? "go" : "Standby", to: r.language) }
                line = compose(r.kind, text: note, word: word)
            }
            let call = CueCall(markID: r.markID, areaID: r.areaID, kind: r.kind, at: r.at, text: line,
                               lineCount: max(1, r.lines.count))
            out.append(PreparedCueCall(call: call, note: note, lines: lines))
        }
        return out
    }

    /// When the voice starts: a go's go word (or, without an onset, its end) lands on the mark;
    /// a standby starts at mark − lead.
    static func startTime(_ call: CueCall, duration: TimeInterval, goOnset: TimeInterval? = nil) -> TimeInterval {
        call.kind == .go ? call.at - (goOnset ?? duration) : call.at
    }

    /// Gap kept between a stack's standby and its go.
    static let standbyGap: TimeInterval = 0.5

    /// A stacked go that would run into its own standby starts as early as it needs to (its go
    /// word still lands on the mark), and the standby moves earlier to finish `standbyGap` before
    /// it. Nothing is skipped; the go is flagged `startsEarly`.
    static func moveStandbysForLongStacks(_ timed: inout [TimedCueCall]) {
        var standby: [CueCallKey: Int] = [:]
        for (i, t) in timed.enumerated() where t.call.kind == .standby { standby[t.key] = i }
        for i in timed.indices where timed[i].call.kind == .go && timed[i].call.lineCount > 1 {
            let g = timed[i]
            guard let s = standby[CueCallKey(markID: g.call.markID, areaID: g.call.areaID, kind: .standby)] else { continue }
            let latestEnd = g.start - standbyGap
            if timed[s].start + timed[s].duration > latestEnd {
                timed[s] = TimedCueCall(call: timed[s].call, start: latestEnd - timed[s].duration, duration: timed[s].duration,
                                        goOnset: nil, estimated: timed[s].estimated)
                timed[i].startsEarly = true
            }
        }
    }

    /// Which stacked go calls would start early, without translating or rendering: phrased in the
    /// note language with the built-in templates and estimated lengths. Mark id → lead-in seconds.
    static func estimatedEarlyStarts(marks: [CueCallMark], settings: CueCallerSettings, noteLanguage: String,
                                     cameraNames: [String] = [], frame: TimeInterval = 1.0 / 30) -> [UUID: TimeInterval] {
        var out: [UUID: TimeInterval] = [:]
        var calls: [CueCall] = []
        var members: [UUID: [UUID]] = [:]
        for r in requests(marks: marks, settings: settings, frame: frame) where r.lines.count > 1 {
            members[r.markID] = r.markIDs
            let lines = r.lines.map(\.text)
            var note = CueCallStack.join(lines, language: noteLanguage)
            if r.kind == .standby, lines.count >= 3 {
                let refs = lines.compactMap { CueCallPresetEditing.leadingCamera(in: $0, names: cameraNames)?.ref }
                if let short = CueCallStack.standbySummary(refs, language: noteLanguage) { note = short }
            }
            calls.append(CueCall(markID: r.markID, areaID: r.areaID, kind: r.kind, at: r.at,
                                 text: CueCallTemplates.text(r.kind, note: note, language: noteLanguage), lineCount: lines.count))
        }
        let rates = Dictionary(settings.areas.map { ($0.id, $0.rate) }, uniquingKeysWith: { a, _ in a })
        for t in timeline(calls, duration: { c in (estimatedDuration(c.text, rate: rates[c.areaID] ?? 0.5), true) })
        where t.startsEarly {
            // Every mark in a same-frame stack shows the flag.
            for id in members[t.call.markID] ?? [t.call.markID] { out[id] = max(out[id] ?? 0, leadIn(t)) }
        }
        return out
    }

    /// How long a go takes to reach its go word (the length the review reports for "starts early").
    static func leadIn(_ t: TimedCueCall) -> TimeInterval { t.goOnset ?? t.duration }

    /// A rough length for text that hasn't been rendered yet (≈ 14 characters a second at rate 0.5).
    static func estimatedDuration(_ text: String, rate: Float) -> TimeInterval {
        let r = Double(max(0.3, min(0.65, rate))) / 0.5
        return 0.25 + Double(text.count) / (14 * r)
    }

    /// Places calls on the timeline and resolves overlaps: within one area, when a call starts
    /// before the previous one has finished, the later call wins and the earlier one fades out
    /// where it starts (a caller never talks over themselves). Areas don't affect each other.
    static func timeline(_ calls: [CueCall], duration: (CueCall) -> (TimeInterval, estimated: Bool)) -> [TimedCueCall] {
        timeline(calls, timing: { c in let d = duration(c); return CueCallTiming(duration: d.0, estimated: d.estimated) })
    }

    /// `timeline` with a go onset per call (from the renderer): the go word, not the end, sits on the mark.
    static func timeline(_ calls: [CueCall], timing: (CueCall) -> CueCallTiming) -> [TimedCueCall] {
        var timed = calls.map { c -> TimedCueCall in
            let d = timing(c)
            let onset = c.kind == .go ? d.goOnset.map { min(max(0, $0), d.duration) } : nil
            return TimedCueCall(call: c, start: startTime(c, duration: d.duration, goOnset: onset), duration: d.duration,
                                goOnset: onset, estimated: d.estimated)
        }
        moveStandbysForLongStacks(&timed)
        timed.sort { ($0.start, $0.call.at) < ($1.start, $1.call.at) }
        var lastInArea: [UUID: Int] = [:]
        for i in timed.indices {
            let area = timed[i].call.areaID
            if let p = lastInArea[area], timed[p].start + timed[p].duration > timed[i].start {
                timed[p].cutAt = max(timed[p].start, timed[i].start)
            }
            lastInArea[area] = i
        }
        return timed
    }
}

/// Decides, tick by tick, which calls to start as time moves. Pure (no clocks, no audio), so seeks,
/// rewinds and timecode dropouts are testable.
///
/// - Arms a call when its start is within `lookahead` of now (the voice itself then starts on the
///   exact frame in the render thread).
/// - Runs late by at most `lateTolerance`; a call later than that is skipped, never bunched up.
/// - A jump (seek, chase to new TC, rewind) or a resume after a stop/dropout skips everything
///   that should already have started and cancels what's sounding: no backlog, no burst.
struct CueCallFollower {
    enum Action: Equatable {
        case arm(TimedCueCall)
        case cancelAll
    }

    var lookahead: TimeInterval = 0.5
    var lateTolerance: TimeInterval = 0.12
    /// Movement beyond elapsed wall time + this counts as a jump.
    var jumpThreshold: TimeInterval = 0.4

    private(set) var lastTime: TimeInterval?
    /// Calls armed or skipped, with the start they had then (a replan that moves a call into
    /// the future re-arms it).
    private(set) var handled: [CueCallKey: TimeInterval] = [:]
    /// Calls skipped because they were already late.
    private(set) var skipped: [CueCallKey] = []

    /// `time` = track time now, nil when time isn't running (stopped, paused, timecode lost,
    /// reverse). `elapsed` = wall seconds since the previous update.
    mutating func update(time: TimeInterval?, elapsed: TimeInterval, calls: [TimedCueCall]) -> [Action] {
        guard let now = time else {
            defer { lastTime = nil }
            return lastTime == nil ? [] : [.cancelAll]
        }
        var actions: [Action] = []
        let jumped: Bool
        let wasRunning = lastTime != nil
        if let last = lastTime {
            let moved = now - last
            jumped = moved < -0.05 || moved > max(0, elapsed) + jumpThreshold
        } else {
            jumped = true
        }
        lastTime = now
        if jumped {
            // A jump while running cancels whatever is armed or sounding (a stop/loss already did).
            if wasRunning { actions.append(.cancelAll) }
            handled = [:]
            for c in calls where c.start < now { handled[c.key] = c.start }
        }
        for c in calls {
            if let h = handled[c.key], !(abs(h - c.start) > 0.01 && c.start > now) { continue }
            if c.start > now + lookahead { continue }
            handled[c.key] = c.start
            if c.start < now - lateTolerance { skipped.append(c.key); continue }
            actions.append(.arm(c))
        }
        return actions
    }

    mutating func reset() { lastTime = nil; handled = [:]; skipped = [] }
}

/// Maps incoming LTC onto a track's timeline and smooths it: LTC arrives whole frames at a time,
/// so the clock is a free-running estimate nudged toward each reading, and re-anchored on a jump.
struct CueCallTimecodeClock {
    private(set) var anchorTrack: TimeInterval?
    private(set) var anchorHost: TimeInterval = 0
    var jumpThreshold: TimeInterval = 0.25
    var gain = 0.15

    /// `reading` = track time from the latest decoded frame (frame-quantized), `frame` = one frame
    /// in seconds, `host` = now. Returns the smoothed track time now.
    mutating func update(reading: TimeInterval, frame: TimeInterval, host: TimeInterval) -> TimeInterval {
        let target = reading + frame / 2
        guard let a = anchorTrack else { anchorTrack = target; anchorHost = host; return target }
        let predicted = a + (host - anchorHost)
        let err = target - predicted
        if abs(err) > jumpThreshold {
            anchorTrack = target; anchorHost = host; return target
        }
        anchorTrack = predicted + err * gain; anchorHost = host
        return anchorTrack!
    }

    mutating func reset() { anchorTrack = nil }
}

/// Rendered call audio: mono PCM plus, for a go, the sample where the go word starts.
struct CueCallRenderedAudio: Sendable {
    var samples: [Float]
    /// Sample offset of the go word's onset; nil = the end of the audio is the go.
    var goOnset: Int? = nil
}

/// Injected render step for renderers that know where the go word is (the language part's
/// `SpeechCueCallRenderer.renderGo(note:template:…)` → `CueCallAudio.goOnset`). Given the call,
/// its translated note, the area and the output sample rate.
typealias CueCallRenderStep = @Sendable (_ call: CueCall, _ note: String, _ area: CueCallArea, _ sampleRate: Double) async throws -> CueCallRenderedAudio

/// Returns the note unchanged — for tests, and areas in the operator's own language.
struct PassthroughCueCallTranslator: CueCallTranslator {
    func translate(_ text: String, from: String, to: String) async throws -> String { text }
}

/// Deterministic stand-in voice for tests and the self-test: a quiet 440 Hz tone whose length
/// follows the text (as speech would). Never meant to be heard; the real voice is
/// `SpeechCueCallRenderer`.
struct StubCueCallRenderer: CueCallVoiceRenderer {
    var secondsPerCharacter = 0.05
    var level: Float = 0.05
    func render(_ text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> [Float] {
        let n = max(1, Int((0.2 + Double(text.count) * secondsPerCharacter) * sampleRate))
        let w = 2 * Double.pi * 440 / sampleRate
        return (0..<n).map { level * Float(sin(w * Double($0))) }
    }

    /// As a render step: the go onset is the end of the audio (onset = duration).
    func renderStep() -> CueCallRenderStep {
        let me = self
        return { call, _, area, sr in
            let pcm = try await me.render(call.text, language: area.language, voiceID: area.voiceID, rate: area.rate, sampleRate: sr)
            return CueCallRenderedAudio(samples: pcm, goOnset: call.kind == .go ? pcm.count : nil)
        }
    }
}
