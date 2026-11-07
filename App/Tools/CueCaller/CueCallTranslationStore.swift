import Foundation

/// A correction typed by someone on the crew for one mark in one language. Wins over the
/// machine translation for as long as the note it was written against hasn't changed.
struct CueCallOverride: Codable, Hashable, Identifiable, Sendable {
    var markID: UUID
    /// Language key ("es", "zh-Hans"); see `CueCallLanguage.key`.
    var language: String
    /// The note text this correction was written for.
    var sourceText: String
    /// What to say instead.
    var text: String
    var updatedAt: Date = .now
    /// Set for a correction of one stacked line (then `sourceText` is that line); nil = the
    /// whole note (corrections written before stacks).
    var line: String? = nil

    var id: String { CueCallTranslationStore.overrideID(markID, language, line: line) }

    /// The mark's note was edited after this correction was written; it is no longer spoken.
    func isStale(currentNote: String) -> Bool {
        CueCallTranslationStore.normalize(currentNote) != CueCallTranslationStore.normalize(sourceText)
    }
}

/// Machine translations and crew corrections, kept as JSON in Application Support/CueCaller.
/// Thread-safe; every change is written through.
final class CueCallTranslationStore: @unchecked Sendable {
    struct CacheEntry: Codable, Hashable, Sendable {
        var source: String
        var target: String
        var text: String
        var translated: String
        var at: Date
    }

    static let shared = CueCallTranslationStore()

    /// Entries kept before the oldest are dropped.
    var cacheLimit = 4000

    private let lock = NSLock()
    private let directory: URL?
    private var cache: [String: CacheEntry] = [:]
    private var overrides: [String: CueCallOverride] = [:]

    /// `directory` nil = memory only (previews). Default: Application Support/CueCaller.
    init(directory: URL? = CueCallTranslationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CueCaller", isDirectory: true)
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func overrideID(_ markID: UUID, _ language: String, line: String?) -> String {
        let base = "\(markID.uuidString)|\(CueCallLanguage.key(language))"
        return line.map { base + "|" + normalize($0) } ?? base
    }

    private static func cacheKey(_ text: String, _ source: String, _ target: String) -> String {
        "\(CueCallLanguage.key(source))|\(CueCallLanguage.key(target))|\(normalize(text))"
    }

    // MARK: Cache

    func cached(_ text: String, from source: String, to target: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[Self.cacheKey(text, source, target)]?.translated
    }

    func storeTranslation(_ translated: String, for text: String, from source: String, to target: String) {
        lock.lock()
        cache[Self.cacheKey(text, source, target)] = CacheEntry(
            source: CueCallLanguage.key(source), target: CueCallLanguage.key(target),
            text: Self.normalize(text), translated: translated, at: .now)
        if cache.count > cacheLimit {
            let drop = cache.sorted { $0.value.at < $1.value.at }.prefix(cache.count - cacheLimit)
            for (k, _) in drop { cache.removeValue(forKey: k) }
        }
        let snapshot = cache
        lock.unlock()
        write(snapshot, "translations.json")
    }

    func clearCache() {
        lock.lock(); cache = [:]; lock.unlock()
        write([String: CacheEntry](), "translations.json")
    }

    var cacheCount: Int { lock.lock(); defer { lock.unlock() }; return cache.count }

    // MARK: Overrides

    /// Set (or clear, with empty `text`) the correction for a mark in a language.
    func setOverride(markID: UUID, language: String, sourceText: String, text: String) {
        let k = CueCallLanguage.key(language)
        let id = "\(markID.uuidString)|\(k)"
        lock.lock()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = CueCallOverride(markID: markID, language: k, sourceText: Self.normalize(sourceText), text: trimmed)
        }
        let snapshot = overrides
        lock.unlock()
        write(snapshot, "overrides.json")
    }

    func removeOverride(markID: UUID, language: String) {
        setOverride(markID: markID, language: language, sourceText: "", text: "")
    }

    /// The stored correction, stale or not (the UI shows stale ones so they can be fixed).
    func override(markID: UUID, language: String) -> CueCallOverride? {
        lock.lock(); defer { lock.unlock() }
        return overrides["\(markID.uuidString)|\(CueCallLanguage.key(language))"]
    }

    /// The correction to speak: only when it was written for this exact note.
    func activeOverride(markID: UUID, language: String, note: String) -> String? {
        guard let o = override(markID: markID, language: language), !o.isStale(currentNote: note) else { return nil }
        return o.text
    }

    /// Correction for a note text without a mark (the plain `CueCallTranslator` path).
    func activeOverride(text: String, language: String) -> String? {
        let k = CueCallLanguage.key(language), n = Self.normalize(text)
        lock.lock(); defer { lock.unlock() }
        return overrides.values
            .filter { $0.language == k && $0.sourceText == n }
            .max { $0.updatedAt < $1.updatedAt }?.text
    }

    // MARK: Per line

    /// Set (or clear, with empty `text`) the correction for one line of a mark's stack.
    func setOverride(markID: UUID, language: String, line: String, text: String) {
        let k = CueCallLanguage.key(language)
        let id = Self.overrideID(markID, k, line: line)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if trimmed.isEmpty {
            overrides.removeValue(forKey: id)
            // A whole-note correction written for this same line goes too.
            let legacy = Self.overrideID(markID, k, line: nil)
            if let o = overrides[legacy], o.sourceText == Self.normalize(line) { overrides.removeValue(forKey: legacy) }
        } else {
            overrides[id] = CueCallOverride(markID: markID, language: k, sourceText: Self.normalize(line), text: trimmed,
                                            line: Self.normalize(line))
        }
        let snapshot = overrides
        lock.unlock()
        write(snapshot, "overrides.json")
    }

    /// The correction for one line: written for that line, or a whole-note correction from before
    /// stacks whose note was exactly this line.
    func override(markID: UUID, language: String, line: String) -> CueCallOverride? {
        let n = Self.normalize(line)
        lock.lock(); defer { lock.unlock() }
        if let o = overrides[Self.overrideID(markID, language, line: n)] { return o }
        if let o = overrides[Self.overrideID(markID, language, line: nil)], o.sourceText == n { return o }
        return nil
    }

    /// The correction to speak for one line (never stale: it's matched by the line's text).
    func activeOverride(markID: UUID, language: String, line: String) -> String? {
        override(markID: markID, language: language, line: line)?.text
    }

    func overrides(for markID: UUID) -> [CueCallOverride] {
        lock.lock(); defer { lock.unlock() }
        return overrides.values.filter { $0.markID == markID }.sorted { $0.language < $1.language }
    }

    var allOverrides: [CueCallOverride] {
        lock.lock(); defer { lock.unlock() }
        return Array(overrides.values)
    }

    // MARK: Disk

    private func load() {
        guard let directory else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: directory.appendingPathComponent("translations.json")),
           let c = try? dec.decode([String: CacheEntry].self, from: d) { cache = c }
        if let d = try? Data(contentsOf: directory.appendingPathComponent("overrides.json")),
           let o = try? dec.decode([String: CueCallOverride].self, from: d) { overrides = o }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        guard let directory else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try enc.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            // Losing the cache costs a re-translation, nothing more.
        }
    }
}
