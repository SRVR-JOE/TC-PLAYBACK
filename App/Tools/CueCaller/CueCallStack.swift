import Foundation
import Observation

// Stacked calls and camera presets.
//
// A mark's `callNote` holds one call per line ("Camera 3, push in\nCamera 5, wide"). A single
// line is exactly the old format. The caller translates each line on its own, then phrases the
// stack once per area: one standby, and one go with the go word last.

// MARK: - Lines

/// One line of a stack, with the mark it was written on (marks on the same frame merge).
struct CueCallLine: Hashable, Sendable {
    let markID: UUID
    let text: String
}

enum CueCallStack {
    /// The calls in a note, one per line, trimmed, blanks dropped.
    static func lines(_ note: String) -> [String] {
        note.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lines as the editor shows them: blanks kept (a line just added is empty), always at least one.
    static func editingLines(_ note: String) -> [String] {
        let l = note.components(separatedBy: "\n")
        return l.isEmpty ? [""] : l
    }

    /// Back to the stored note.
    static func note(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// The note with blank lines and stray spaces removed (what's saved when editing ends).
    static func tidy(_ note: String) -> String { lines(note).joined(separator: "\n") }

    /// One-line summary for lists: "Camera 3, push in · Camera 5, wide".
    static func summary(_ note: String) -> String { lines(note).joined(separator: " · ") }

    // MARK: Phrasing

    /// Languages written without spaces between sentences.
    static func isCJK(_ language: String) -> Bool { ["ja", "zh"].contains(CueCallLanguage.code(language)) }

    /// Sentence separator between stacked calls.
    static func separator(_ language: String) -> String { isCJK(language) ? "。" : ". " }

    private static let trailing = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".,;:。、，；…"))

    /// Lines joined into one spoken note: "Camera 3, push in. Camera 5, wide".
    static func join(_ lines: [String], language: String) -> String {
        let cjk = isCJK(language)
        let parts = lines.map { $0.trimmingCharacters(in: trailing) }.filter { !$0.isEmpty }
        return parts.enumerated().map { i, s in i == 0 || cjk ? s : capitalizedFirst(s) }
            .joined(separator: separator(language))
    }

    static func capitalizedFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "and" for lists, per language key. CJK lists use an enumeration comma instead.
    static let conjunction: [String: String] = [
        "en": "and", "es": "y", "fr": "et", "de": "und", "it": "e", "pt": "e", "nl": "en", "sv": "och",
    ]

    /// "3, 5 and 7" / "3、5、7".
    static func list(_ items: [String], language: String) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        let k = CueCallLanguage.key(language), code = CueCallLanguage.code(language)
        if code == "ja" || code == "zh" { return items.joined(separator: "、") }
        if code == "ko" { return items.joined(separator: ", ") }
        let and = conjunction[k] ?? conjunction["en"]!
        return items.dropLast().joined(separator: ", ") + " \(and) " + items.last!
    }

    /// Languages that capitalise nouns (the camera word stays capitalised mid-sentence).
    private static func keepsNounCase(_ language: String) -> Bool { CueCallLanguage.code(language) == "de" }

    /// The short standby for a stack of 3 or more: "cameras 3, 5 and 7", or "camera 3, Jib and
    /// Steadicam" when some are named. `names` are the leading cameras already in `language`
    /// (numbers stay digits). nil when no line starts with a camera.
    static func standbySummary(_ refs: [CueCameraRef], language: String) -> String? {
        guard !refs.isEmpty else { return nil }
        let k = CueCallLanguage.key(language), code = CueCallLanguage.code(language)
        let tight = code == "ja" || code == "zh"
        func word(_ table: [String: String]) -> String {
            let w = table[k] ?? table[code] ?? table["en"]!
            return keepsNounCase(language) || tight ? w : w.lowercased()
        }
        let numbers = refs.compactMap { if case .numbered(let n) = $0 { return n } else { return nil } }
        if numbers.count == refs.count {
            let w = word(refs.count == 1 ? CueCallLexicon.cameraWord : CueCallLexicon.camerasWord)
            return w + (tight ? "" : " ") + list(numbers, language: language)
        }
        // Numbered cameras first under one camera word ("cameras 3, 5"), then the named ones.
        let names = refs.compactMap { if case .named(let n) = $0 { return n } else { return nil } }
        var items: [String] = []
        if let first = numbers.first {
            let w = word(numbers.count == 1 ? CueCallLexicon.cameraWord : CueCallLexicon.camerasWord)
            items = [w + (tight ? "" : " ") + first] + numbers.dropFirst()
        }
        items += names
        return list(items, language: language)
    }
}

/// A camera at the start of a call line.
enum CueCameraRef: Hashable, Sendable {
    /// "Camera 3", "Cam 3": just the number.
    case numbered(String)
    /// A renamed camera ("Jib", "Steadicam").
    case named(String)
}

extension CuePoint {
    /// The calls on this mark, one per line.
    var callLines: [String] { CueCallStack.lines(callNote) }
    /// How many calls are stacked on this mark.
    var callCount: Int { callLines.count }
}

// MARK: - Camera presets

/// The operator's camera names and shot words, tapped into a call line. Stored as JSON in
/// UserDefaults under `key`.
struct CueCameraPresets: Codable, Equatable, Sendable {
    static let key = "cueCaller.cameraPresets"
    static let count = 12

    static let defaultShots = ["Push in", "Pull out", "Wide", "Tight", "Hold", "Pan left", "Pan right",
                               "Tilt up", "Tilt down", "Follow", "Clear"]
    static func defaultName(_ i: Int) -> String { "Camera \(i + 1)" }

    /// Twelve names, index 0 = Camera 1.
    var cameras: [String] = (0..<count).map(defaultName)
    var shots: [String] = defaultShots

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decodeIfPresent([String].self, forKey: .cameras) ?? []
        cameras = (0..<Self.count).map { i in
            let n = i < names.count ? names[i].trimmingCharacters(in: .whitespaces) : ""
            return n.isEmpty ? Self.defaultName(i) : n
        }
        shots = try c.decodeIfPresent([String].self, forKey: .shots) ?? Self.defaultShots
    }

    /// The camera's name, falling back to "Camera N" when blank.
    func name(_ i: Int) -> String {
        guard i >= 0, i < cameras.count else { return Self.defaultName(i) }
        let n = cameras[i].trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? Self.defaultName(i) : n
    }
    func isRenamed(_ i: Int) -> Bool { name(i) != Self.defaultName(i) }

    /// Label on a key: "Cam 3" for an unnamed camera, else the name.
    func keyLabel(_ i: Int) -> String { isRenamed(i) ? name(i) : "Cam \(i + 1)" }

    static func load(_ d: UserDefaults = .standard) -> CueCameraPresets {
        guard let data = d.data(forKey: key), let p = try? JSONDecoder().decode(CueCameraPresets.self, from: data) else { return .init() }
        return p
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    /// Renamed cameras (names that aren't "Camera N"), for recognising them at a line start.
    var customNames: [String] { (0..<Self.count).filter(isRenamed).map(name) }
}

/// What tapping a camera key does to the current line.
enum CueCameraTap: Equatable {
    /// Replace the current line with this text.
    case replace(String)
    /// The current line is a full call: start a new stacked line with this text.
    case newLine(String)
}

/// Pure line editing for the preset keys (tested; the views only apply the result).
enum CueCallPresetEditing {
    /// A camera at the very start of `line`: the matched text, what it refers to, and the rest
    /// after its separator. "Camera 3, push in" → ("Camera 3", .numbered("3"), "push in").
    static func leadingCamera(in line: String, names: [String]) -> (match: String, ref: CueCameraRef, rest: String)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        // Renamed cameras first, longest first, so "Jib 2" wins over "Jib".
        for n in names.sorted(by: { $0.count > $1.count }) where !n.isEmpty {
            guard s.range(of: n, options: [.anchored, .caseInsensitive]) != nil else { continue }
            let after = s.dropFirst(n.count)
            if let c = after.first, c.isLetter || c.isNumber { continue }
            return (String(s.prefix(n.count)), .named(n), rest(after))
        }
        let pattern = #"(?i)^(?:cameras?|cams?|c[aá]maras?|c[aâ]meras?|kameras?|cam[eé]ras?|カメラ|摄像机|攝影機|카메라)\s*(\d+)(?![\p{L}\p{N}])"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let all = Range(m.range, in: s), let num = Range(m.range(at: 1), in: s) else { return nil }
        return (String(s[all]), .numbered(String(s[num])), rest(s[all.upperBound...]))
    }

    private static func rest(_ s: Substring) -> String {
        String(s).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",.;:-–")))
    }

    /// Tapping camera `name` with `line` current:
    /// - empty line → "Camera 3, "
    /// - the line is only a camera ("Camera 5, ") → swap it
    /// - any other filled line → a new stacked line starting with the camera
    /// (`swapCamera` changes the camera on a full line; the key's menu offers it).
    static func tapCamera(_ name: String, line: String, names: [String]) -> CueCameraTap {
        let s = line.trimmingCharacters(in: .whitespaces)
        let start = name + ", "
        if s.isEmpty { return .replace(start) }
        if let lead = leadingCamera(in: s, names: names), lead.rest.isEmpty { return .replace(start) }
        return .newLine(start)
    }

    /// Swap whatever camera starts `line` for `name`, keeping the rest ("Camera 3, push in" →
    /// "Jib, push in"). Adds the camera when the line has none.
    static func swapCamera(_ name: String, line: String, names: [String]) -> String {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard let lead = leadingCamera(in: s, names: names) else { return s.isEmpty ? name + ", " : name + ", " + lowercasedFirst(s) }
        return lead.rest.isEmpty ? name + ", " : name + ", " + lead.rest
    }

    /// Tapping a shot word: appended to the line. "Camera 3, " + Push in → "Camera 3, push in";
    /// "Camera 3, push in" + Hold → "Camera 3, push in, hold"; an empty line takes it as is.
    static func tapShot(_ shot: String, line: String) -> String {
        let w = shot.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return line }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return w }
        if trimmed.hasSuffix(",") { return trimmed + " " + lowercasedFirst(w) }
        return trimmed + ", " + lowercasedFirst(w)
    }

    /// "Push in" → "push in", but "PTZ left" stays.
    static func lowercasedFirst(_ s: String) -> String {
        let chars = Array(s)
        guard let f = chars.first, f.isUppercase else { return s }
        if chars.count > 1, chars[1].isUppercase { return s }
        return f.lowercased() + String(chars.dropFirst())
    }

    // MARK: Whole-note edits (the editor's line `index` is the current line)

    /// Camera key on line `index` of `note`. Returns the new note and the line now current.
    static func applyCamera(_ name: String, to note: String, line index: Int, names: [String]) -> (note: String, line: Int) {
        var lines = CueCallStack.editingLines(note)
        let i = max(0, min(index, lines.count - 1))
        switch tapCamera(name, line: lines[i], names: names) {
        case .replace(let t):
            lines[i] = t
            return (CueCallStack.note(lines), i)
        case .newLine(let t):
            // Reuse an empty line right after the current one rather than stacking blanks.
            if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines[i + 1] = t
            } else {
                lines.insert(t, at: i + 1)
            }
            return (CueCallStack.note(lines), i + 1)
        }
    }

    /// "Use on this line": swap the camera on line `index`, keeping the rest of the call.
    static func applySwap(_ name: String, to note: String, line index: Int, names: [String]) -> String {
        var lines = CueCallStack.editingLines(note)
        let i = max(0, min(index, lines.count - 1))
        lines[i] = swapCamera(name, line: lines[i], names: names)
        return CueCallStack.note(lines)
    }

    /// Shot key on line `index`.
    static func applyShot(_ shot: String, to note: String, line index: Int) -> String {
        var lines = CueCallStack.editingLines(note)
        let i = max(0, min(index, lines.count - 1))
        lines[i] = tapShot(shot, line: lines[i])
        return CueCallStack.note(lines)
    }

    /// "Add call": a new empty line after `index` (or the existing empty one there). Returns the
    /// new note and the line to focus.
    static func addLine(to note: String, after index: Int) -> (note: String, line: Int) {
        var lines = CueCallStack.editingLines(note)
        let i = max(0, min(index, lines.count - 1))
        if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { return (note, i) }
        if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty { return (note, i + 1) }
        lines.insert("", at: i + 1)
        return (CueCallStack.note(lines), i + 1)
    }

    static func removeLine(from note: String, at index: Int) -> String {
        var lines = CueCallStack.editingLines(note)
        guard lines.indices.contains(index) else { return note }
        lines.remove(at: index)
        return CueCallStack.note(lines)
    }

    static func moveLine(in note: String, from: Int, to: Int) -> String {
        var lines = CueCallStack.editingLines(note)
        guard lines.indices.contains(from), from != to else { return note }
        let l = lines.remove(at: from)
        lines.insert(l, at: max(0, min(lines.count, to)))
        return CueCallStack.note(lines)
    }

    /// Index of the camera key that starts `line`, for lighting it.
    static func activeCamera(line: String, presets: CueCameraPresets) -> Int? {
        guard let lead = leadingCamera(in: line, names: presets.customNames) else { return nil }
        switch lead.ref {
        case .named(let n):
            return (0..<CueCameraPresets.count).first { presets.name($0).caseInsensitiveCompare(n) == .orderedSame }
        case .numbered(let n):
            guard let i = Int(n), i >= 1, i <= CueCameraPresets.count, !presets.isRenamed(i - 1) else { return nil }
            return i - 1
        }
    }
}

/// The caller's keys: camera names come from the current show's camera brief
/// (`CameraBriefStore`), shot words are the operator's own (saved in UserDefaults).
@MainActor
@Observable
final class CueCameraPresetStore {
    static let shared = CueCameraPresetStore()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let briefs: CameraBriefStore
    /// Told about every change to the names or shots (the caller re-reads renamed cameras).
    @ObservationIgnored var onChange: ((CueCameraPresets) -> Void)?
    private var shots: [String] {
        didSet {
            guard shots != oldValue else { return }
            var p = CueCameraPresets(); p.shots = shots; p.save(defaults)
            onChange?(presets)
        }
    }

    init(defaults: UserDefaults = .standard, briefs: CameraBriefStore = .shared) {
        self.defaults = defaults
        self.briefs = briefs
        shots = CueCameraPresets.load(defaults).shots
        let previous = briefs.onChange
        briefs.onChange = { [weak self] in
            previous?()
            if let self { self.onChange?(self.presets) }
        }
    }

    /// Names from the current brief (cameras it doesn't list are "Camera N"), plus the shots.
    var presets: CueCameraPresets {
        var p = CueCameraPresets()
        p.cameras = briefs.brief().keyNames
        p.shots = shots
        return p
    }

    /// The current brief's camera behind key `i` (0-based), for the mission hint.
    func briefCamera(_ i: Int) -> BriefCamera? { briefs.brief().camera(number: i + 1) }

    func rename(_ i: Int, to name: String) {
        guard i >= 0, i < CueCameraPresets.count else { return }
        briefs.rename(number: i + 1, to: name)
    }
    func resetShots() { shots = CueCameraPresets.defaultShots }
    func addShot(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !shots.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        shots.append(t)
    }
    func removeShots(at offsets: IndexSet) {
        shots = shots.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
    func moveShots(from: IndexSet, to: Int) {
        var a = shots
        let moving = from.map { a[$0] }
        let before = from.filter { $0 < to }.count
        for i in from.sorted(by: >) { a.remove(at: i) }
        a.insert(contentsOf: moving, at: max(0, min(a.count, to - before)))
        shots = a
    }
}
