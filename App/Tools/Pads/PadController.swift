import Foundation
import Observation
import TCKit

/// Owns the pad library and drives the LTC generator from pad presses and nudges.
@Observable
final class PadController {
    private(set) var library: PadLibrary
    /// Pad currently feeding the generator.
    private(set) var activePadID: UUID?
    /// Incremented on every fire — drives the haptic.
    private(set) var fireCount = 0
    var errorMessage: String?

    /// The config we last handed to the engine. Lets us tell our generator apart from a show cue.
    private(set) var activeConfig: GeneratorConfig?
    /// The active pad's cue point and duration (for re-computing run time after a nudge).
    private var activeCue: Timecode?
    private var activeDuration: TimeInterval?

    // Wall-clock fallback for the readout, used until the engine reports generator timecode.
    private var anchorTC: Timecode?
    private var anchorDate: Date?
    private var pausedTC: Timecode?

    @ObservationIgnored private let store: PadStore
    @ObservationIgnored let engine: PlaybackEngine

    init(store: PadStore = PadStore(), engine: PlaybackEngine = .shared) {
        self.store = store
        self.engine = engine
        library = store.load() ?? PadLibrary.makeDefault()
        if library.banks.isEmpty { library = PadLibrary.makeDefault() }
        if library.selectedBankID == nil || !library.banks.contains(where: { $0.id == library.selectedBankID }) {
            library.selectedBankID = library.banks.first?.id
        }
    }

    // MARK: Bank access

    var bankIndex: Int { library.banks.firstIndex { $0.id == library.selectedBankID } ?? 0 }
    var bank: PadBank { library.banks[bankIndex] }

    func selectBank(_ id: UUID) { library.selectedBankID = id; persist() }

    func updateBank(_ change: (inout PadBank) -> Void) {
        change(&library.banks[bankIndex])
        persist()
    }

    func addBank() {
        guard library.banks.count < PadLibrary.maxBanks else { return }
        let b = PadBank(name: library.nextBankName(), rate: bank.rate)
        library.banks.append(b)
        library.selectedBankID = b.id
        persist()
    }

    func deleteCurrentBank() {
        guard library.banks.count > 1 else { return }
        library.banks.remove(at: bankIndex)
        library.selectedBankID = library.banks.first?.id
        persist()
    }

    // MARK: Pad editing

    func pad(_ id: UUID) -> TCPad? { bank.pads.first { $0.id == id } }

    func newPad() -> TCPad {
        let last = bank.pads.last.map { $0.startTimecode(in: bank) }
        let start = last.map { Timecode(hours: min(23, $0.hours + 1), rate: bank.rate) } ?? Timecode(hours: 1, rate: bank.rate)
        return TCPad(label: "Pad \(bank.pads.count + 1)", start: start, side: bank.pads.last?.side ?? .right,
                     levelDBFS: bank.pads.last?.levelDBFS ?? -10)
    }

    func upsert(_ pad: TCPad) {
        updateBank { b in
            if let i = b.pads.firstIndex(where: { $0.id == pad.id }) { b.pads[i] = pad } else { b.pads.append(pad) }
        }
    }

    func delete(_ id: UUID) {
        if id == activePadID { stop() }
        updateBank { $0.pads.removeAll { $0.id == id } }
    }

    func duplicate(_ id: UUID) {
        updateBank { b in
            guard let i = b.pads.firstIndex(where: { $0.id == id }) else { return }
            var copy = b.pads[i]
            copy.id = UUID()
            copy.label += " copy"
            b.pads.insert(copy, at: i + 1)
        }
    }

    /// Move `id` to the slot currently held by `target`.
    func move(_ id: UUID, onto target: UUID) {
        guard id != target else { return }
        updateBank { b in
            guard let from = b.pads.firstIndex(where: { $0.id == id }),
                  let to = b.pads.firstIndex(where: { $0.id == target }) else { return }
            let p = b.pads.remove(at: from)
            b.pads.insert(p, at: to)
        }
    }

    enum FillMode { case replace, append }
    func quickFillHours(_ mode: FillMode) {
        updateBank { b in
            let side = b.pads.last?.side ?? .right
            let pads = PadBank.hourPads(rate: b.rate, side: side)
            if mode == .replace { b.pads = pads } else { b.pads += pads }
        }
    }

    // MARK: Fire / transport

    /// True when the engine is playing (or paused on) the generator we started.
    var isOurs: Bool {
        guard let activeConfig else { return false }
        return engine.source == .generator(activeConfig)
    }

    var isRunning: Bool { isOurs && engine.transport == .playing }
    var isPaused: Bool { isOurs && engine.transport == .paused }

    /// The show-cue check the view uses before firing.
    var showCueIsPlaying: Bool {
        guard engine.transport == .playing else { return false }
        if case .file = engine.source { return true }
        return engine.source != .none && !isOurs
    }

    func fire(_ pad: TCPad) {
        let b = bank
        let rate = pad.rate(in: b)
        let cue = pad.startTimecode(in: b)
        let start = PadMath.generatorStart(cue: cue, preRoll: pad.preRoll(in: b))
        activePadID = pad.id
        activeCue = cue
        activeDuration = pad.duration
        let config = GeneratorConfig(start: start, rate: rate,
                                     duration: PadMath.remainingDuration(from: start, cue: cue, duration: pad.duration),
                                     side: pad.side, levelDBFS: pad.levelDBFS)
        run(config, play: true)
        fireCount += 1
    }

    func nudge(_ n: Nudge) {
        guard isOurs, let current = liveTimecode, var config = activeConfig else { return }
        let target = PadMath.nudge(current, by: n)
        config.start = target
        if let cue = activeCue {
            config.duration = PadMath.remainingDuration(from: target, cue: cue, duration: activeDuration)
            if config.duration == 0 { config.duration = 1 / config.rate.fps }
        }
        run(config, play: engine.transport == .playing)
    }

    func togglePause() {
        guard isOurs else { return }
        if engine.transport == .playing {
            pausedTC = liveTimecode
            engine.pause()
        } else {
            if let p = pausedTC { anchorTC = p; anchorDate = Date() }
            pausedTC = nil
            engine.play()
        }
    }

    func stop() {
        if isOurs { engine.stop() }
        activePadID = nil
        pausedTC = nil
    }

    private func run(_ config: GeneratorConfig, play: Bool) {
        do {
            try engine.load(.generator(config))
            activeConfig = config
            anchorTC = config.start
            anchorDate = Date()
            pausedTC = play ? nil : config.start
            if play { engine.play() } else { engine.pause() }
        } catch {
            errorMessage = "Couldn't start timecode: \(error.localizedDescription)"
            activePadID = nil
        }
    }

    // MARK: Readout

    /// Live generator timecode: the engine clock when it reports our generator, otherwise a
    /// wall-clock estimate from the last relocate.
    var liveTimecode: Timecode? {
        guard isOurs, let config = activeConfig else { return nil }
        if engine.clock.source == .generator, let tc = engine.clock.timecode, tc.rate == config.rate { return tc }
        if engine.transport == .paused { return pausedTC ?? anchorTC }
        guard let anchorTC, let anchorDate else { return nil }
        var elapsed = Date().timeIntervalSince(anchorDate)
        if let d = config.duration { elapsed = min(elapsed, d) }
        return anchorTC.adding(frames: Int((elapsed * config.rate.fps).rounded(.down)))
    }

    // MARK: Persistence

    private func persist() {
        do { try store.save(library) } catch { errorMessage = "Couldn't save pads: \(error.localizedDescription)" }
    }
}
