import Foundation
import SwiftUI
import Translation

// On-device translation of call notes with Apple's Translation framework. Nothing leaves the
// device: language models are downloaded once through the system prompt, then everything runs
// locally. iOS 26 and later translate directly; iOS 18–25 need `CueCallTranslationHost` in the
// view hierarchy (Translation only hands out sessions through SwiftUI there).

/// Whether a language pair can be translated right now.
enum CueCallPairStatus: String, Codable, Sendable {
    /// Same language: the note is spoken as written.
    case same
    /// Both language models are on the device.
    case installed
    /// Supported, but the models still have to be downloaded (system prompt).
    case needsDownload
    /// Apple doesn't translate this pair.
    case unsupported

    var label: String {
        switch self {
        case .same: "Same language"
        case .installed: "Ready"
        case .needsDownload: "Needs download"
        case .unsupported: "Not supported"
        }
    }
    var isReady: Bool { self == .same || self == .installed }
}

/// The text to speak for one area, and where it came from.
struct CueCallTranslationResult: Hashable, Sendable {
    enum Origin: String, Sendable {
        /// Same language; the note as written.
        case passthrough
        /// A crew correction for this mark and language.
        case override
        /// A translation made earlier.
        case cache
        /// Translated just now.
        case translated
        /// Translation failed; the original note is used (see `problem`).
        case original
    }
    var text: String
    var origin: Origin
    var numbers: CueCallNumberGuard.Outcome = .intact
    /// Why the original note is being used, for the UI.
    var problem: String? = nil
}

enum CueCallTranslationError: LocalizedError, Equatable {
    case needsDownload(source: String, target: String)
    case unsupported(source: String, target: String)
    /// The translation changed or dropped a number; it isn't safe to call.
    case numbersChanged
    /// iOS 18–25: no `CueCallTranslationHost` is on screen to provide a session.
    case hostNotAttached
    case timedOut

    var errorDescription: String? {
        switch self {
        case .needsDownload(let s, let t):
            "\(CueCallLanguage.label(s)) to \(CueCallLanguage.label(t)) needs a language download."
        case .unsupported(let s, let t):
            "\(CueCallLanguage.label(s)) to \(CueCallLanguage.label(t)) can't be translated on this device."
        case .numbersChanged: "The translation changed a number, so the note is called as written."
        case .hostNotAttached: "Translation isn't available on this screen."
        case .timedOut: "Translation took too long."
        }
    }
}

/// Translates call notes, with a persistent cache and crew overrides (override > cache > machine).
final class AppleCueCallTranslator: CueCallTranslator, @unchecked Sendable {
    /// The machine translation step: (text, source tag, target tag) → translated text.
    typealias Engine = @Sendable (_ text: String, _ source: String, _ target: String) async throws -> String

    static let shared = AppleCueCallTranslator()

    let store: CueCallTranslationStore
    private let engine: Engine

    /// `engine` nil = Apple's on-device Translation. Tests pass a stand-in.
    init(store: CueCallTranslationStore = .shared, engine: Engine? = nil) {
        self.store = store
        self.engine = engine ?? AppleCueCallTranslator.systemEngine
    }

    // MARK: CueCallTranslator

    /// Override (matched by note text) > same language > cache > on-device translation.
    /// Throws when the pair isn't installed or the translation would change a number.
    func translate(_ text: String, from: String, to: String) async throws -> String {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return text }
        if let o = store.activeOverride(text: note, language: to) { return o }
        if CueCallLanguage.same(from, to) { return text }
        return try await machine(note, from: from, to: to).text
    }

    // MARK: Per mark

    /// What an area should hear for a mark. Never throws: on any failure the original note is
    /// returned with `problem` set, so a call always goes out.
    func call(note: String, markID: UUID, from: String, to: String) async -> CueCallTranslationResult {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .init(text: "", origin: .passthrough) }
        if let o = store.activeOverride(markID: markID, language: to, note: n) { return .init(text: o, origin: .override) }
        if let o = store.activeOverride(text: n, language: to) { return .init(text: o, origin: .override) }
        if CueCallLanguage.same(from, to) { return .init(text: note, origin: .passthrough) }
        do {
            return try await machine(n, from: from, to: to)
        } catch {
            return .init(text: n, origin: .original, problem: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The crew correction store, for the editor.
    func setOverride(markID: UUID, language: String, note: String, text: String) {
        store.setOverride(markID: markID, language: language, sourceText: note, text: text)
    }

    private func machine(_ note: String, from: String, to: String) async throws -> CueCallTranslationResult {
        if let c = store.cached(note, from: from, to: to) { return .init(text: c, origin: .cache) }
        let expanded = CueCallLexicon.expandForTranslation(note, language: from)
        let raw = try await engine(expanded, CueCallLanguage.translationTag(from), CueCallLanguage.translationTag(to))
        let checked = CueCallNumberGuard.check(source: expanded, translated: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard checked.outcome != .lost else { throw CueCallTranslationError.numbersChanged }
        store.storeTranslation(checked.text, for: note, from: from, to: to)
        return .init(text: checked.text, origin: .translated, numbers: checked.outcome)
    }

    // MARK: Availability

    /// Installed / needs download / unsupported, for one pair.
    func status(from: String, to: String) async -> CueCallPairStatus {
        if CueCallLanguage.same(from, to) { return .same }
        let s = await LanguageAvailability().status(
            from: Locale.Language(identifier: CueCallLanguage.translationTag(from)),
            to: Locale.Language(identifier: CueCallLanguage.translationTag(to)))
        switch s {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// Status for every area language, keyed by the tag passed in.
    func statuses(from: String, to targets: [String]) async -> [String: CueCallPairStatus] {
        var out: [String: CueCallPairStatus] = [:]
        for t in targets where out[t] == nil { out[t] = await status(from: from, to: t) }
        return out
    }

    /// Show the system download prompt for a pair. Needs `CueCallTranslationHost` on screen.
    @MainActor
    func requestDownload(from: String, to: String) async throws {
        try await CueCallTranslationBroker.shared.prepare(
            from: CueCallLanguage.translationTag(from), to: CueCallLanguage.translationTag(to))
    }

    /// True when translation works without a host view (iOS 26 and later).
    static var translatesWithoutHost: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    // MARK: System engine

    static let systemEngine: Engine = { text, source, target in
        if #available(iOS 26, *) {
            return try await CueCallDirectSessions.shared.translate(text, from: source, to: target)
        }
        // Never let a call trigger the download prompt mid-show: only installed pairs go through.
        switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: break
        case .supported: throw CueCallTranslationError.needsDownload(source: source, target: target)
        default: throw CueCallTranslationError.unsupported(source: source, target: target)
        }
        return try await CueCallTranslationBroker.shared.translate(text, from: source, to: target)
    }
}

// MARK: - iOS 26+: direct sessions

/// Sessions made with `TranslationSession(installedSource:target:)`, one per pair.
/// They never prompt; a pair that isn't installed throws `needsDownload`.
@available(iOS 26, *)
actor CueCallDirectSessions {
    static let shared = CueCallDirectSessions()
    private var sessions: [String: TranslationSession] = [:]

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let key = "\(from)|\(to)"
        let session: TranslationSession
        if let s = sessions[key] {
            session = s
        } else {
            let src = Locale.Language(identifier: from), tgt = Locale.Language(identifier: to)
            switch await LanguageAvailability().status(from: src, to: tgt) {
            case .installed: break
            case .supported: throw CueCallTranslationError.needsDownload(source: from, target: to)
            default: throw CueCallTranslationError.unsupported(source: from, target: to)
            }
            session = TranslationSession(installedSource: src, target: tgt)
            sessions[key] = session
        }
        do {
            if #available(iOS 26.4, *) {
                // Mark camera numbers and crew terms so the model leaves them alone.
                var a = AttributedString(text)
                for r in CueCallNumberGuard.protectedRanges(in: text) {
                    guard let lo = AttributedString.Index(r.lowerBound, within: a),
                          let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
                    a[lo..<hi].translation.skipsTranslation = true
                }
                return try await session.translate(a).targetText
            }
            return try await session.translate(text).targetText
        } catch {
            sessions[key] = nil
            if TranslationError.notInstalled ~= error { throw CueCallTranslationError.needsDownload(source: from, target: to) }
            throw error
        }
    }

    /// Drop sessions (after a language download, or memory pressure).
    func reset() { sessions = [:] }
}

// MARK: - Host path (iOS 18–25) and download prompts (all versions)

/// Feeds translation requests to the session SwiftUI's `.translationTask` hands out.
/// One pair is served at a time; requests for other pairs wait their turn.
@MainActor
final class CueCallTranslationBroker: ObservableObject {
    static let shared = CueCallTranslationBroker()

    struct Pair: Hashable { var source: String; var target: String }

    /// Drives `.translationTask` in `CueCallTranslationHost`.
    @Published private(set) var configuration: TranslationSession.Configuration?
    /// The pair whose download prompt is up, if any.
    @Published private(set) var downloading: Pair?
    @Published private(set) var lastError: String?

    /// One waiting request. Resumes exactly once (served, failed or timed out).
    private final class Job {
        enum Kind { case translate(String), prepare }
        let kind: Kind
        private var continuation: CheckedContinuation<String, Error>?
        init(_ kind: Kind, _ c: CheckedContinuation<String, Error>) { self.kind = kind; continuation = c }
        var isDone: Bool { continuation == nil }
        func finish(_ r: Result<String, Error>) { continuation?.resume(with: r); continuation = nil }
    }
    private var queues: [Pair: [Job]] = [:]
    private var order: [Pair] = []
    private var active: Pair?
    private var serving = false
    private var hosts = 0

    var hostAttached: Bool { hosts > 0 }

    func hostAppeared() { hosts += 1; kick() }
    func hostDisappeared() { hosts = max(0, hosts - 1) }

    /// Translate through the host's session. Fails fast when no host is on screen.
    func translate(_ text: String, from: String, to: String, timeout: Double = 15) async throws -> String {
        try await run(.translate(text), Pair(source: from, target: to), timeout: timeout)
    }

    /// Ask the system to download the models for a pair (shows its prompt).
    func prepare(from: String, to: String) async throws {
        _ = try await run(.prepare, Pair(source: from, target: to), timeout: nil)
        if #available(iOS 26, *) { await CueCallDirectSessions.shared.reset() }
    }

    private func run(_ kind: Job.Kind, _ pair: Pair, timeout: Double?) async throws -> String {
        guard hostAttached else { throw CueCallTranslationError.hostNotAttached }
        return try await withCheckedThrowingContinuation { c in
            let job = Job(kind, c)
            queues[pair, default: []].append(job)
            if !order.contains(pair) { order.append(pair) }
            if let timeout {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                    guard !job.isDone else { return }
                    self?.queues[pair]?.removeAll { $0 === job }
                    job.finish(.failure(CueCallTranslationError.timedOut))
                }
            }
            kick()
        }
    }

    /// Point the task at the next waiting pair (or re-run it for the current one).
    private func kick() {
        guard hostAttached, !serving, let next = order.first else { return }
        if active == next, configuration != nil {
            configuration?.invalidate()
        } else {
            active = next
            configuration = .init(source: Locale.Language(identifier: next.source),
                                  target: Locale.Language(identifier: next.target))
        }
    }

    /// Called by the host's `.translationTask` with a session for `configuration`.
    func serve(_ session: TranslationSession) async {
        guard let pair = active else { return }
        serving = true
        while let job = queues[pair]?.first {
            queues[pair]?.removeFirst()
            guard !job.isDone else { continue }
            switch job.kind {
            case .translate(let text):
                do { job.finish(.success(try await session.translate(text).targetText)) }
                catch { lastError = error.localizedDescription; job.finish(.failure(error)) }
            case .prepare:
                downloading = pair
                do { try await session.prepareTranslation(); job.finish(.success("")) }
                catch { lastError = error.localizedDescription; job.finish(.failure(error)) }
                downloading = nil
            }
        }
        queues[pair] = nil
        order.removeAll { $0 == pair }
        serving = false
        kick()
    }
}

/// Invisible view that gives the cue caller translation sessions and download prompts.
/// Attach once near the root of the cue caller screens: `.cueCallTranslationHost()`.
struct CueCallTranslationHost: View {
    @ObservedObject private var broker = CueCallTranslationBroker.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(broker.configuration) { session in
                await broker.serve(session)
            }
            .onAppear { broker.hostAppeared() }
            .onDisappear { broker.hostDisappeared() }
    }
}

extension View {
    /// Hosts cue caller translation (needed on iOS 18–25, and for language downloads).
    func cueCallTranslationHost() -> some View { background(CueCallTranslationHost()) }
}
