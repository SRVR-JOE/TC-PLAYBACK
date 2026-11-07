import Foundation

// NOTE: the Apple Watch work (WatchLink) has its own clock sync on another branch. This is a
// small, self-contained NTP-style estimator so the crew framework builds on its own. The two
// should be merged into one shared implementation when both branches land.

/// One NTP-style exchange. t0 follower send, t1 master receive, t2 master send, t3 follower
/// receive. t0/t3 on the follower's clock, t1/t2 on the master's.
struct ClockSample: Equatable {
    var t0, t1, t2, t3: TimeInterval
    /// master − follower clock offset estimate.
    var offset: TimeInterval { ((t1 - t0) + (t2 - t3)) / 2 }
    /// Network round trip (master processing time removed).
    var roundTrip: TimeInterval { (t3 - t0) - (t2 - t1) }
}

/// Median-filtered offset and round-trip over the last `window` samples. Samples with a round
/// trip well above the best recent one are dropped first: a slow round trip is where asymmetric
/// delay (the error NTP can't see) is largest.
struct ClockSyncEstimator: Equatable {
    var window = 15
    /// Keep samples whose round trip is within this factor of the window's minimum (plus 1 ms).
    var rttTolerance = 2.0
    private(set) var samples: [ClockSample] = []

    init(window: Int = 15, rttTolerance: Double = 2.0) { self.window = max(1, window); self.rttTolerance = rttTolerance }

    mutating func add(_ s: ClockSample) {
        guard s.roundTrip >= 0, s.roundTrip.isFinite else { return }
        samples.append(s)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    mutating func reset() { samples.removeAll() }

    private var good: [ClockSample] {
        guard let best = samples.map(\.roundTrip).min() else { return [] }
        let limit = best * rttTolerance + 0.001
        return samples.filter { $0.roundTrip <= limit }
    }

    /// master − follower, seconds. nil until the first sample.
    var offset: TimeInterval? { Self.median(good.map(\.offset)) }
    var roundTrip: TimeInterval? { Self.median(samples.map(\.roundTrip)) }
    var isSynced: Bool { samples.count >= 3 }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

/// The follower's view of the show clock: local host time + offset → master host time →
/// track time. Small corrections are slewed (bled in at `slewRate`) so the displayed time
/// never jumps; large ones, a seek, or a transport change snap.
struct FollowerClock: Equatable {
    /// Errors larger than this snap.
    var snapThreshold: TimeInterval = 0.05
    /// Seconds of correction per second of time (0.1 = up to 10% fast/slow while slewing).
    var slewRate: Double = 0.1

    private(set) var state: CrewShowState?
    private(set) var offset: TimeInterval = 0
    /// Error still to bleed off: shown = target − residual(t).
    private var residual: TimeInterval = 0
    private var residualAt: TimeInterval = 0

    init(snapThreshold: TimeInterval = 0.05, slewRate: Double = 0.1) {
        self.snapThreshold = snapThreshold; self.slewRate = slewRate
    }

    /// The exact track time from the latest state and offset (no slewing).
    func target(atLocal t: TimeInterval) -> TimeInterval? {
        state.map { max(0, $0.trackTime(atMasterHost: t + offset)) }
    }

    /// What to display at local host time `t`.
    func trackTime(atLocal t: TimeInterval) -> TimeInterval? {
        guard let target = target(atLocal: t) else { return nil }
        return target - residualNow(t)
    }

    /// New offset estimate from clock sync.
    mutating func updateOffset(_ newOffset: TimeInterval, atLocal t: TimeInterval) {
        let shown = trackTime(atLocal: t)
        offset = newOffset
        reconcile(previouslyShown: shown, at: t, forceSnap: false)
    }

    /// New show state from the master.
    mutating func apply(_ s: CrewShowState, atLocal t: TimeInterval) {
        let shown = trackTime(atLocal: t)
        let snap = state == nil || state?.epoch != s.epoch || state?.transport != s.transport
            || state?.trackID != s.trackID || s.rate == 0
        state = s
        reconcile(previouslyShown: shown, at: t, forceSnap: snap)
    }

    private mutating func reconcile(previouslyShown shown: TimeInterval?, at t: TimeInterval, forceSnap: Bool) {
        guard let target = target(atLocal: t), let shown, !forceSnap else { residual = 0; residualAt = t; return }
        let error = target - shown
        if abs(error) > snapThreshold { residual = 0 } else { residual = error }
        residualAt = t
    }

    private func residualNow(_ t: TimeInterval) -> TimeInterval {
        guard residual != 0 else { return 0 }
        let left = abs(residual) - slewRate * max(0, t - residualAt)
        return left > 0 ? (residual > 0 ? left : -left) : 0
    }
}
