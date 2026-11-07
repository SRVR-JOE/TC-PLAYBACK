import SwiftUI
import QuartzCore
import Observation

/// Fires mark triggers (screen flash, camera light, haptic, readout flash) on the display frame
/// where the mark is HEARD, not when the 30 Hz UI position happens to pass it.
///
/// Each display frame it reads the render thread's sample position, subtracts the output latency
/// (what's still on its way to the speaker — large on Bluetooth/AirPlay), and looks ahead to the
/// moment the next frame reaches the glass. A mark that falls before that moment fires now, so the
/// flash lands on the frame closest to the sound. Same reference as live marks, so a mark dropped
/// on a hit flashes on that hit.
@MainActor
@Observable
final class CueTriggerClock {
    static let shared = CueTriggerClock()

    struct Mark: Equatable { let id: UUID; let time: TimeInterval; let colorHex: String? }

    /// Track time the listener is hearing now (valid while playing).
    private(set) var heardTime: TimeInterval = 0
    /// The last mark fired and when (host time).
    private(set) var lastHit: (id: UUID, at: CFTimeInterval)?

    @ObservationIgnored var marks: [Mark] = []
    #if DEBUG
    @ObservationIgnored var debugLog: [(mark: TimeInterval, heardAtFire: TimeInterval, heardOnGlass: TimeInterval)] = []
    #endif
    @ObservationIgnored var compensateLatency = true
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var previous: TimeInterval?
    @ObservationIgnored private weak var engine: PlaybackEngine?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var lastRaw: TimeInterval = -1
    @ObservationIgnored private var lastRawAt: CFTimeInterval = 0

    /// How far behind the rendered position the sound reaches the ear.
    static var outputDelay: TimeInterval { CueMarkTiming.sessionOutputLatency }

    func start(engine: PlaybackEngine) {
        users += 1
        self.engine = engine
        guard link == nil else { return }
        ScreenFlash.shared.prepare()
        let l = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        link?.invalidate(); link = nil; previous = nil
    }

    func isFlashing(_ now: CFTimeInterval = CACurrentMediaTime(), hold: Double = 0.6) -> Bool {
        lastHit.map { now - $0.at < hold } ?? false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let engine, engine.transport == .playing else { previous = nil; lastRaw = -1; return }
        let now = CACurrentMediaTime()
        let delay = compensateLatency ? Self.outputDelay : 0
        // The render position steps once per audio buffer (5–20 ms). Between steps, advance it by
        // the time since the step was seen, capped, so a stalled engine can't run the clock away.
        let raw = engine.preciseTime
        if raw != lastRaw { lastRaw = raw; lastRawAt = now }
        let position = raw + min(max(0, now - lastRawAt), 0.05)
        let heard = position - delay
        heardTime = max(0, heard)
        // What will be heard when this frame is on screen.
        // Fire on the frame whose on-screen moment is closest to the mark: look half a frame
        // past this frame's glass time (±4 ms at 120 Hz, ±8 ms at 60 Hz).
        let frame = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        let atGlass = heard + max(0, link.targetTimestamp - now) + frame / 2
        defer { previous = atGlass }
        guard let prev = previous else { return }
        guard let hit = Self.crossed(marks, from: prev, to: atGlass) else { return }
        lastHit = (hit.id, now)
        #if DEBUG
        debugLog.append((mark: hit.time, heardAtFire: heard, heardOnGlass: atGlass - frame / 2))
        #endif
        Haptics.tick()
        CueFlash.fire(markHex: hit.colorHex)
    }

    /// The last mark in (from, to]; nil when moving backwards or jumping (a seek).
    nonisolated static func crossed(_ marks: [Mark], from: TimeInterval, to: TimeInterval) -> Mark? {
        guard to > from, to - from < 0.5 else { return nil }
        return marks.last { $0.time > from && $0.time <= to }
    }

    /// CADisplayLink retains its target; the proxy keeps that from pinning the clock.
    private final class Proxy: NSObject {
        weak var owner: CueTriggerClock?
        init(_ o: CueTriggerClock) { owner = o }
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { owner?.tick(l) } }
    }
}
