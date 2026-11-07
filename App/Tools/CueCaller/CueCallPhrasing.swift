import Foundation

// Language side of the cue caller: how calls are phrased per language, which languages we
// offer, crew vocabulary that has to be read correctly, and the guard that keeps camera
// numbers intact through translation.

// MARK: - Languages

/// Language helpers. Areas carry a BCP-47 tag ("es-MX"); translation and overrides work on a
/// coarser key ("es", "zh-Hans") so regional variants of one language share corrections.
enum CueCallLanguage {
    /// Languages offered in the area picker, in display order.
    static let offered: [String] = [
        "en-US", "en-GB", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "pt-BR",
        "nl-NL", "ja-JP", "ko-KR", "zh-Hans", "zh-Hant",
    ]

    /// Display name in the device's language: "Spanish (Mexico)".
    static func label(_ tag: String, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: tag) ?? tag
    }

    /// Two- or three-letter language code, lowercased ("es" for "es-MX").
    static func code(_ tag: String) -> String {
        let t = tag.replacingOccurrences(of: "_", with: "-")
        return (Locale.Language(identifier: t).languageCode?.identifier ?? String(t.split(separator: "-").first ?? ""))
            .lowercased()
    }

    /// Script for Chinese ("Hans"/"Hant"), nil for everything else.
    static func chineseScript(_ tag: String) -> String? {
        guard code(tag) == "zh" else { return nil }
        let t = tag.replacingOccurrences(of: "_", with: "-")
        let lower = t.lowercased()
        if lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo") { return "Hant" }
        if lower.contains("hans") { return "Hans" }
        let max = Locale.Language(identifier: t).maximalIdentifier.lowercased()
        return max.contains("hant") ? "Hant" : "Hans"
    }

    /// Key used for the translation cache and overrides: "es", "pt", "zh-Hans".
    static func key(_ tag: String) -> String {
        if let s = chineseScript(tag) { return "zh-\(s)" }
        return code(tag)
    }

    /// Same spoken language (regional variants count as the same): no translation needed.
    static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// Tag to hand to the Translation framework. Region is kept where Apple ships a separate
    /// model (en-US/en-GB, pt-BR, zh scripts), otherwise the bare language.
    static func translationTag(_ tag: String) -> String {
        if let s = chineseScript(tag) { return "zh-\(s)" }
        return tag.replacingOccurrences(of: "_", with: "-")
    }

    /// The operator's own language, used as the note source when nothing else is set.
    static var operatorDefault: String {
        let id = Locale.preferredLanguages.first ?? Locale.current.identifier
        return id.replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: - Call templates

/// How one language phrases a call. `{note}` is replaced by the (translated) note.
/// The go template must end on `goWord`: the engine lands the end of the audio on the mark.
struct CueCallTemplate: Codable, Hashable, Sendable {
    /// Language key this template is for ("es", "zh-Hans").
    var language: String
    /// "Standby, {note}"
    var standby: String
    /// "{note}… go"
    var go: String
    /// The final word of `go`, spoken on the mark ("go", "ya", "top").
    var goWord: String
    /// Said on the mark when the note is empty (no note but a call is wanted).
    var bareGo: String

    static let placeholder = "{note}"

    func standbyText(_ note: String) -> String { fill(standby, note) }
    func goText(_ note: String) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? bareGo : fill(go, n)
    }

    /// The call split at the go word, for renderers that place the go word separately.
    func goParts(_ note: String) -> (lead: String, goWord: String) {
        let full = goText(note)
        guard let r = full.range(of: goWord, options: [.backwards, .caseInsensitive]) else { return (full, "") }
        let lead = full[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return (lead, String(full[r]))
    }

    /// True when the go word is the last word of the go call (ignoring trailing punctuation).
    var goWordIsLast: Bool {
        let w = goWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, go.contains(Self.placeholder) else { return false }
        let strip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let tail = go.trimmingCharacters(in: strip)
        let bare = bareGo.trimmingCharacters(in: strip)
        return tail.lowercased().hasSuffix(w.lowercased())
            && !tail.lowercased().hasSuffix(Self.placeholder.lowercased())
            && bare.lowercased().hasSuffix(w.lowercased())
    }

    private func fill(_ t: String, _ note: String) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = t.replacingOccurrences(of: Self.placeholder, with: n)
        // Avoid ", ," or "。…" doubling when the note already ends in punctuation.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        for doubled in [",,", ".…", "。…", "，，", "、、"] {
            s = s.replacingOccurrences(of: doubled, with: String(doubled.last!))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Built-in templates, broadcast-crew register: short, clear, go word last.
enum CueCallTemplates {
    static let builtIn: [CueCallTemplate] = [
        .init(language: "en", standby: "Standby, {note}", go: "{note}… go", goWord: "go", bareGo: "Go"),
        .init(language: "es", standby: "Atención, {note}", go: "{note}… ya", goWord: "ya", bareGo: "Ya"),
        .init(language: "fr", standby: "Attention, {note}", go: "{note}… top", goWord: "top", bareGo: "Top"),
        .init(language: "de", standby: "Achtung, {note}", go: "{note}… los", goWord: "los", bareGo: "Los"),
        .init(language: "it", standby: "Attenzione, {note}", go: "{note}… via", goWord: "via", bareGo: "Via"),
        .init(language: "pt", standby: "Atenção, {note}", go: "{note}… já", goWord: "já", bareGo: "Já"),
        .init(language: "nl", standby: "Stand-by, {note}", go: "{note}… go", goWord: "go", bareGo: "Go"),
        .init(language: "ja", standby: "スタンバイ、{note}", go: "{note}… キュー", goWord: "キュー", bareGo: "キュー"),
        .init(language: "ko", standby: "스탠바이, {note}", go: "{note}… 큐", goWord: "큐", bareGo: "큐"),
        .init(language: "zh-Hans", standby: "准备，{note}", go: "{note}… 走", goWord: "走", bareGo: "走"),
        .init(language: "zh-Hant", standby: "準備，{note}", go: "{note}… 走", goWord: "走", bareGo: "走"),
    ]

    /// Template for an area language, falling back to the base language, then English.
    /// `custom` (per-area edits, later) wins when it has a matching language key.
    static func template(for tag: String, custom: [CueCallTemplate] = []) -> CueCallTemplate {
        let k = CueCallLanguage.key(tag)
        if let c = custom.first(where: { $0.language == k && $0.goWordIsLast }) { return c }
        if let b = builtIn.first(where: { $0.language == k }) { return b }
        let base = CueCallLanguage.code(tag)
        if let b = builtIn.first(where: { $0.language == base || $0.language.hasPrefix(base + "-") }) { return b }
        return builtIn[0]
    }

    static func text(_ kind: CueCall.Kind, note: String, language: String, custom: [CueCallTemplate] = []) -> String {
        let t = template(for: language, custom: custom)
        return kind == .standby ? t.standbyText(note) : t.goText(note)
    }
}

// MARK: - Crew vocabulary

/// Shorthand that operators type and voices misread. Two passes:
/// - `expandForTranslation`: before translating, in the note's language ("Cam 3" → "Camera 3"),
///   so the translator sees real words.
/// - `speakable`: right before speech, in the area's language (spelled acronyms, respellings).
enum CueCallLexicon {
    /// The word for "camera" per language key.
    static let cameraWord: [String: String] = [
        "en": "Camera", "es": "Cámara", "fr": "Caméra", "de": "Kamera", "it": "Camera",
        "pt": "Câmera", "nl": "Camera", "ja": "カメラ", "ko": "카메라", "zh-Hans": "摄像机", "zh-Hant": "攝影機",
    ]
    static let camerasWord: [String: String] = [
        "en": "Cameras", "es": "Cámaras", "fr": "Caméras", "de": "Kameras", "it": "Camere",
        "pt": "Câmeras", "nl": "Camera's", "ja": "カメラ", "ko": "카메라", "zh-Hans": "摄像机", "zh-Hant": "攝影機",
    ]

    /// Terms the translator must leave alone (also marked skip-translation where supported).
    static let protectedTerms = ["LX", "SFX", "VT", "PTZ", "Jib", "Steadicam", "VTR", "VO"]

    /// Respellings by language key. Matched as whole words, case-insensitive.
    static let respell: [String: [(String, String)]] = [
        "en": [("LX", "L X"), ("SFX", "S F X"), ("VTR", "V T R"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("VO", "V O"), ("Steadicam", "Steady-cam"), ("Jib", "Jib")],
        "es": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Stedicam"), ("Jib", "Yib")],
        "fr": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Stédicam"), ("Jib", "Djib")],
        "de": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Steddikäm"), ("Jib", "Dschibb")],
        "it": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Stedicam"), ("Jib", "Gib")],
        "pt": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Stedicam"), ("Jib", "Djib")],
        "nl": [("LX", "L X"), ("SFX", "S F X"), ("VT", "V T"), ("PTZ", "P T Z"),
               ("Steadicam", "Steddiekem"), ("Jib", "Dzjib")],
        "ja": [("Steadicam", "ステディカム"), ("Jib", "ジブ"), ("PTZ", "P T Z"), ("SFX", "S F X"), ("LX", "L X"), ("VT", "V T")],
        "ko": [("Steadicam", "스테디캠"), ("Jib", "지브"), ("PTZ", "P T Z"), ("SFX", "S F X"), ("LX", "L X"), ("VT", "V T")],
        "zh-Hans": [("Steadicam", "斯坦尼康"), ("Jib", "摇臂"), ("PTZ", "P T Z"), ("SFX", "S F X"), ("LX", "L X"), ("VT", "V T")],
        "zh-Hant": [("Steadicam", "斯坦尼康"), ("Jib", "搖臂"), ("PTZ", "P T Z"), ("SFX", "S F X"), ("LX", "L X"), ("VT", "V T")],
    ]

    /// "Cam 3" → "Camera 3", "Cams 1 and 2" → "Cameras 1 and 2", "Cam3" → "Camera 3".
    static func expandCam(_ text: String, language: String) -> String {
        let k = CueCallLanguage.key(language)
        let one = cameraWord[k] ?? cameraWord["en"]!
        let many = camerasWord[k] ?? camerasWord["en"]!
        var s = replaceWord(text, pattern: #"(?i)\bcams\b"#, with: many)
        s = replaceWord(s, pattern: #"(?i)\bcam(?=\d)"#, with: one + " ")
        s = replaceWord(s, pattern: #"(?i)\bcam\b"#, with: one)
        return s
    }

    static func expandForTranslation(_ text: String, language: String) -> String {
        expandCam(text, language: language)
    }

    /// Text as it should be handed to the voice for `language`.
    static func speakable(_ text: String, language: String) -> String {
        let k = CueCallLanguage.key(language)
        var s = expandCam(text, language: language)
        for (term, say) in respell[k] ?? respell["en"]! where term != say {
            s = replaceWord(s, pattern: "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])", with: say)
        }
        return s
    }

    private static func replaceWord(_ s: String, pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

// MARK: - Number guard

/// Camera numbers and cue numbers must come out of translation exactly as they went in.
/// Every digit run in the source must appear, in order, in the translation.
enum CueCallNumberGuard {
    enum Outcome: Equatable, Sendable {
        /// Numbers came through untouched.
        case intact
        /// The translator changed digits (or used full-width ones); they were put back.
        case repaired
        /// The numbers could not be matched up; the translation is not safe to speak.
        case lost
    }

    /// Digit runs, with full-width digits folded to ASCII. "2.5" stays one token.
    static func numbers(in s: String) -> [String] {
        let folded = foldDigits(s)
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#) else { return [] }
        return re.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)).compactMap {
            Range($0.range, in: folded).map { String(folded[$0]) }
        }
    }

    /// Full-width and other Unicode decimal digits → ASCII.
    static func foldDigits(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.properties.numericType == .decimal, let v = u.properties.numericValue, !(u.value >= 0x30 && u.value <= 0x39) {
                out.append(Unicode.Scalar(UInt8(48 + Int(v))))
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// Compare by digits only, so "2.5" → "2,5" (a correct localisation) still counts as intact.
    private static func digitsOnly(_ t: String) -> String { t.filter(\.isASCII).filter(\.isNumber) }

    /// Check `translated` against `source`, repairing it when the count of numbers matches.
    static func check(source: String, translated: String) -> (text: String, outcome: Outcome) {
        let src = numbers(in: source)
        let folded = foldDigits(translated)
        let dst = numbers(in: folded)
        if src.map(digitsOnly) == dst.map(digitsOnly) {
            return (folded, folded == translated ? .intact : .repaired)
        }
        guard src.count == dst.count,
              let re = try? NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#) else {
            return (translated, .lost)
        }
        // Same count, different values: put the source numbers back in order.
        var result = folded
        let matches = re.matches(in: folded, range: NSRange(folded.startIndex..., in: folded))
        for (i, m) in matches.enumerated().reversed() {
            guard let r = Range(m.range, in: result) else { return (translated, .lost) }
            result.replaceSubrange(r, with: src[i])
        }
        return (result, .repaired)
    }

    /// Ranges in `s` the translator should not touch: numbers and crew terms.
    static func protectedRanges(in s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        let terms = CueCallLexicon.protectedTerms.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"\d+(?:[.,:]\d+)*|(?i)(?<![\p{L}\p{N}])(?:"# + terms + #")(?![\p{L}\p{N}])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range, in: s) { out.append(r) }
        }
        return out
    }
}
